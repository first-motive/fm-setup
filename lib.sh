#!/usr/bin/env bash
#
# lib.sh — shared functions for fm-setup's front doors and steps.
#
# SOURCED, never executed. install.sh, run.sh, and every scripts/steps/*.sh
# source this file, so a step runs standalone as well as through a front door.
#
# Over a curl pipe there is no lib.sh on disk; install.sh fetches this file and
# loads it with `eval`. Keep every definition self-contained and side-effect free
# at load time. Do not set shell options here — the front door owns
# `set -euo pipefail`, and a sourced file that flips options surprises callers.
#
# SECURITY: over the pipe this file is loaded with `eval`, so everything here is
# trusted code running in the caller's shell. Keep it minimal, never put a secret
# in it, and pin the fetch URL to a release tag.

# Refuse direct execution: `return` succeeds only in a sourced context.
if ! (return 0 2>/dev/null); then
  echo "lib.sh is a function library; source it, do not execute it." >&2
  exit 1
fi

FM_BRAND="${FM_BRAND:-First Motive}"

# Colour helpers, disabled when stdout is not a terminal so logs stay clean.
if [ -t 1 ]; then
  FM_C_RESET="$(printf '\033[0m')"
  FM_C_BOLD="$(printf '\033[1m')"
  FM_C_DIM="$(printf '\033[2m')"
  FM_C_GREEN="$(printf '\033[32m')"
  FM_C_YELLOW="$(printf '\033[33m')"
  FM_C_RED="$(printf '\033[31m')"
  FM_C_BLUE="$(printf '\033[34m')"
else
  FM_C_RESET="" FM_C_BOLD="" FM_C_DIM="" FM_C_GREEN="" FM_C_YELLOW="" FM_C_RED="" FM_C_BLUE=""
fi

fm_log()  { printf '%s\n' "${FM_C_BLUE}==>${FM_C_RESET} ${FM_C_BOLD}$*${FM_C_RESET}"; }
fm_info() { printf '    %s\n' "$*"; }
fm_ok()   { printf '%s\n' "${FM_C_GREEN}    ✓${FM_C_RESET} $*"; }
fm_skip() { printf '%s\n' "${FM_C_DIM}    ↷ $* (skip)${FM_C_RESET}"; }
fm_warn() { printf '%s\n' "${FM_C_YELLOW}    !${FM_C_RESET} $*" >&2; }
fm_err()  { printf '%s\n' "${FM_C_RED}    ✗${FM_C_RESET} $*" >&2; }

fm_banner() { printf '%s\n' "── ${FM_BRAND} · fm-setup ──"; }

# --- Platform --------------------------------------------------------------

# Echo the OS as linux | macos, or fail loudly on an unsupported platform.
fm_detect_os() {
  local uname_s
  uname_s="$(uname -s)"
  case "$uname_s" in
    Linux)  printf 'linux\n' ;;
    Darwin) printf 'macos\n' ;;
    *) fm_err "unsupported OS: $uname_s"; return 1 ;;
  esac
}

# Echo the arch as x86_64 | aarch64, or fail loudly on an unsupported one.
fm_detect_arch() {
  local uname_m
  uname_m="$(uname -m)"
  case "$uname_m" in
    x86_64|amd64)  printf 'x86_64\n' ;;
    arm64|aarch64) printf 'aarch64\n' ;;
    *) fm_err "unsupported arch: $uname_m"; return 1 ;;
  esac
}

# Echo the machine role as workstation | jetson, guessed from the hardware.
# A Jetson carries /etc/nv_tegra_release; its device-tree model names the board.
# The --workstation / --jetson flags override this, so a wrong guess is never
# load-bearing.
fm_detect_role() {
  if [ -f /etc/nv_tegra_release ] || grep -qi tegra /proc/device-tree/model 2>/dev/null; then
    printf 'jetson\n'
  else
    printf 'workstation\n'
  fi
}

fm_require_linux() {
  [ "$(uname -s)" = "Linux" ] || { fm_err "Linux only"; return 1; }
}

# Echo the Ubuntu codename (noble, jammy, …), empty on a non-Ubuntu host.
fm_os_codename() {
  [ -f /etc/os-release ] || return 0
  # shellcheck disable=SC1091
  . /etc/os-release && printf '%s\n' "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
}

fm_has_cmd()    { command -v "$1" >/dev/null 2>&1; }
fm_has_docker() { fm_has_cmd docker && docker info >/dev/null 2>&1; }
fm_require_cmd() {
  fm_has_cmd "$1" || { fm_err "missing dependency: $1"; return 1; }
}

# Return success when an apt package is installed.
fm_has_pkg() { dpkg -s "$1" >/dev/null 2>&1; }

# Verify a file against an expected sha256 before it is executed. A mismatch
# returns non-zero so the caller can abort before running a tampered download.
fm_verify_checksum() {
  local file="$1" expected="$2" actual
  [ -f "$file" ] || { fm_err "file not found: $file"; return 1; }
  if fm_has_cmd sha256sum; then
    actual="$(sha256sum "$file" | cut -d' ' -f1)"
  elif fm_has_cmd shasum; then
    actual="$(shasum -a 256 "$file" | cut -d' ' -f1)"
  else
    fm_err "no sha256 tool found (sha256sum or shasum)"
    return 1
  fi
  if [ "$actual" != "$expected" ]; then
    fm_err "checksum mismatch for $file"
    fm_err "  expected $expected"
    fm_err "  actual   $actual"
    return 1
  fi
}

# --- File edits ------------------------------------------------------------

# fm_ensure_line FILE LINE — append LINE to FILE once. Creates FILE if absent.
# Idempotent: a re-run finds the exact line already present and does nothing.
fm_ensure_line() {
  local file="$1" line="$2"
  [ -f "$file" ] || touch "$file"
  grep -qxF "$line" "$file" 2>/dev/null || printf '%s\n' "$line" >>"$file"
}

# fm_strip_line FILE LINE — remove every exact-match LINE from FILE.
#
# The scratch file comes from mktemp inside the target's own directory, not from
# a predictable "$file.tmp": these steps run as root, and a predictable name in a
# world-writable directory lets a local attacker pre-plant a symlink and redirect
# the write. Same directory keeps the final mv atomic; the mode is copied over so
# the rewrite cannot loosen permissions.
fm_strip_line() {
  local file="$1" line="$2" tmp
  [ -f "$file" ] || return 0
  tmp="$(mktemp "$(dirname "$file")/.fm-strip.XXXXXX")" || return 1
  if grep -vxF "$line" "$file" >"$tmp"; then
    chmod --reference="$file" "$tmp" 2>/dev/null || chmod "$(stat -f '%Lp' "$file" 2>/dev/null || echo 644)" "$tmp"
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
  fi
}

# --- Prompts ---------------------------------------------------------------

# fm_pause "message" — print and wait for Enter. A no-op under NONINTERACTIVE=1.
fm_pause() {
  if [ "${NONINTERACTIVE:-0}" = "1" ]; then
    fm_warn "$* (NONINTERACTIVE — not pausing)"
    return 0
  fi
  printf '%s\n' "${FM_C_YELLOW}    →${FM_C_RESET} $*"
  read -r -p "    Press Enter to continue… " _
}

# fm_confirm "question" — y/N prompt. Auto-declines under NONINTERACTIVE=1, so a
# security-sensitive step never applies itself unattended.
fm_confirm() {
  if [ "${NONINTERACTIVE:-0}" = "1" ]; then
    fm_warn "$* — auto-declined (NONINTERACTIVE)"
    return 1
  fi
  local reply
  read -r -p "    ${FM_C_YELLOW}?${FM_C_RESET} $* [y/N] " reply
  case "$reply" in [Yy]) return 0 ;; *) return 1 ;; esac
}

# --- Step protocol ---------------------------------------------------------
#
# Every scripts/steps/*.sh defines do_check / do_install / do_uninstall, then
# ends with `fm_dispatch "$@"`. The three modes are the whole contract:
#
#   check      report state, change nothing, always exit 0
#   install    make it so, idempotently
#   uninstall  reverse what install did, where reversible
#
# fm_dispatch [MODE] [ARG…] — route a step to its do_<mode> function. Arguments
# after MODE are forwarded, letting a step scope its work to named targets.
fm_dispatch() {
  local mode="${1:-install}"
  shift 2>/dev/null || true
  case "$mode" in
    check)     do_check "$@" ;;
    install)   do_install "$@" ;;
    uninstall) do_uninstall "$@" ;;
    *) fm_err "unknown mode: $mode (use check|install|uninstall)"; return 1 ;;
  esac
}

# --- Step gating -----------------------------------------------------------
#
# The front door fills FM_ONLY (from --only) and FM_SKIP (from --skip) before
# iterating a manifest. Default both to genuinely empty arrays so a step sourced
# standalone always runs. `${arr+x}` is the bash 3.2 safe existence test.
[ "${FM_SKIP+x}" ] || FM_SKIP=()
[ "${FM_ONLY+x}" ] || FM_ONLY=()

# fm_collect FM_ONLY|FM_SKIP "a,b,c" — split a comma-separated flag value into
# the named array, appending.
#
# The target is matched against the two known arrays rather than assigned through
# `eval "$arr+=(…)"`. Both the array name and the value come from the command
# line, and an eval would expand the value a second time inside the eval'd
# string — enough for `--only 'x"); rm -rf /; ("'` to run as whatever user is
# provisioning the machine, which is root.
fm_collect() {
  local arr="$1" raw="$2" part
  local parts=()
  local IFS=','
  read -r -a parts <<<"$raw"
  for part in ${parts[@]+"${parts[@]}"}; do
    [ -n "$part" ] || continue
    case "$arr" in
      FM_ONLY) FM_ONLY+=("$part") ;;
      FM_SKIP) FM_SKIP+=("$part") ;;
      *) fm_err "fm_collect: unknown target array '$arr'"; return 1 ;;
    esac
  done
}

# _fm_in_list NEEDLE ITEM… — 0 when NEEDLE equals one of the ITEMs.
_fm_in_list() {
  local needle="$1"; shift
  local item
  for item in "$@"; do
    [ "$item" = "$needle" ] && return 0
  done
  return 1
}

# fm_is_enabled ID DEFAULT — decide whether step ID runs.
#   --only set     → run only ids in FM_ONLY
#   id in FM_SKIP  → skip
#   otherwise      → follow DEFAULT (on|off)
fm_is_enabled() {
  local id="$1" default="$2"
  if [ "${#FM_ONLY[@]}" -gt 0 ] && [ -n "${FM_ONLY[0]:-}" ]; then
    _fm_in_list "$id" "${FM_ONLY[@]}"
    return
  fi
  if [ "${#FM_SKIP[@]}" -gt 0 ] && [ -n "${FM_SKIP[0]:-}" ]; then
    _fm_in_list "$id" "${FM_SKIP[@]}" && return 1
  fi
  [ "$default" = "on" ]
}

# fm_steps_for ROLE — echo the role's manifest entries, one per line.
# Keeps the role→registry mapping in one place; callers read it with `while read`
# rather than reaching for the arrays directly.
fm_steps_for() {
  local role="$1" entry
  case "$role" in
    workstation) for entry in "${WORKSTATION_STEPS[@]:-}"; do [ -n "$entry" ] && printf '%s\n' "$entry"; done ;;
    jetson)      for entry in "${JETSON_STEPS[@]:-}";      do [ -n "$entry" ] && printf '%s\n' "$entry"; done ;;
    *) fm_err "unknown role: $role (use workstation|jetson)"; return 1 ;;
  esac
}

# fm_warn_unknown_ids ROLE — warn about a --only / --skip id the role does not
# have. A typo would otherwise skip the whole run in silence, which reads exactly
# like a successful no-op.
fm_warn_unknown_ids() {
  local role="$1" wanted id file default known=()
  while IFS='|' read -r id file default; do
    known+=("$id")
  done < <(fm_steps_for "$role")

  for wanted in ${FM_ONLY[@]+"${FM_ONLY[@]}"} ${FM_SKIP[@]+"${FM_SKIP[@]}"}; do
    [ -n "$wanted" ] || continue
    _fm_in_list "$wanted" "${known[@]}" || fm_warn "no step '$wanted' in role '$role'"
  done
}

# fm_list_steps ROLE — print the role's step table and return.
fm_list_steps() {
  local role="$1" entry id file default
  fm_log "fm-setup steps — $role"
  printf '    %-16s %-26s %s\n' "ID" "FILE" "DEFAULT"
  while IFS='|' read -r id file default; do
    printf '    %-16s %-26s %s\n' "$id" "$file" "$default"
  done < <(fm_steps_for "$role")
}

# fm_run_steps MODE ROLE STEPS_DIR [DRY] — run the role's manifest in MODE.
# uninstall walks the manifest in reverse so dependents come down before the
# things they depend on. A dry run prints the plan and touches nothing.
fm_run_steps() {
  local mode="$1" role="$2" steps_dir="$3" dry="${4:-0}"
  local entry id file default
  local entries=()

  # Steps a role shares read this to pick the role's variant — the ROS distro,
  # for one, differs between the 26.04 workstation and the 22.04 Jetson.
  export FM_ROLE="$role"

  while IFS= read -r entry; do
    entries+=("$entry")
  done < <(fm_steps_for "$role")

  if [ "$mode" = "uninstall" ]; then
    local reversed=() i
    for ((i = ${#entries[@]} - 1; i >= 0; i--)); do
      reversed+=("${entries[$i]}")
    done
    entries=("${reversed[@]}")
  fi

  if [ "${#entries[@]}" -eq 0 ]; then
    fm_warn "no steps registered for role '$role'"
    return 0
  fi

  fm_warn_unknown_ids "$role"

  for entry in "${entries[@]}"; do
    IFS='|' read -r id file default <<<"$entry"
    if ! fm_is_enabled "$id" "$default"; then
      fm_skip "$id"
      continue
    fi
    if [ "$dry" = "1" ]; then
      fm_info "would run: $id ($file) [$mode]"
      continue
    fi
    fm_log "$id ($file) [$mode]"
    bash "$steps_dir/$file" "$mode"
    echo
  done
}
