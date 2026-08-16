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

# --- Release ---------------------------------------------------------------
#
# The release tag is written down exactly once, in install.sh, and every other
# reader derives it from there.
#
# install.sh holds the literal because it is the one file that ever arrives
# alone: fetched over a curl pipe with no checkout behind it, it has nothing
# else on disk to read the value out of, so its default cannot be delegated to
# a VERSION file or to this library. Everything else in the repo does have the
# checkout, and a tag repeated in four files is a tag that is correct in three
# of them the morning after a release — which is how the flash seed came to
# provision appliances from `main` while the README still advertised v0.1.x.

# fm_release_tag [ROOT] — echo the release tag this checkout is pinned to.
#
# ROOT defaults to FM_ROOT, which every step and verb already sets to the
# repository root; callers outside that convention pass it explicitly. Fails
# loudly rather than echoing a guess, because the two things this value is used
# for — fetching code and baking a bootstrap URL into an appliance's first boot
# — are both worse done wrong than not done.
fm_release_tag() {
  local root="${1:-${FM_ROOT:-}}" front tag
  front="$root/install.sh"
  [ -n "$root" ] && [ -f "$front" ] || {
    fm_err "cannot read the release tag: no install.sh at '${root:-<unset>}'"
    return 1
  }
  # Matched against the assignment's exact shape rather than any v-looking
  # string in the file, so the header's example curl commands — which carry the
  # same tag, and are rewritten from this one by scripts/dev/release-tag.sh —
  # can never be what gets parsed.
  # The single quotes are load-bearing: the pattern matches the literal text
  # ${FM_TAG:-…} in install.sh, which must reach sed unexpanded.
  # shellcheck disable=SC2016
  tag="$(sed -n 's/^FM_TAG="\${FM_TAG:-\(v[^}]*\)}".*/\1/p' "$front" | head -1)"
  [ -n "$tag" ] || {
    fm_err "no FM_TAG assignment found in $front"
    return 1
  }
  printf '%s\n' "$tag"
}

# --- Machine identity ------------------------------------------------------
#
# Readers of the identity card, for the steps and front doors that need to know
# which machine they are on. The writer lives in scripts/run/machine.sh; nothing
# here changes the card.
#
# Defaults are repeated inline rather than taken from the manifest alone,
# because over the curl pipe lib.sh is eval'd before any manifest exists and a
# step sourced standalone gets the same answer either way.

# Echo the path to this machine's identity card, whether or not it exists.
# FM_MACHINE_FILE overrides it, which is how a rehearsal container and a test
# point at a card outside the real system paths.
#
# The override exists for tests and for container rehearsal, so a card written
# under it is never written as root — see card_sudo in scripts/run/machine.sh.
fm_machine_file() {
  if [ -n "${FM_MACHINE_FILE:-}" ]; then
    printf '%s\n' "$FM_MACHINE_FILE"
    return 0
  fi
  case "$(uname -s)" in
    Darwin) printf '%s\n' "${FM_MACHINE_FILE_MACOS:-${XDG_CONFIG_HOME:-$HOME/.config}/fm/machine.json}" ;;
    *)      printf '%s\n' "${FM_MACHINE_FILE_LINUX:-/etc/fm/machine.json}" ;;
  esac
}

# Return success when this machine has an identity card. A machine without one
# is not broken: a laptop running the desktop app in client mode has no
# workspace and needs no card, so callers ask before they read.
fm_machine_exists() { [ -f "$(fm_machine_file)" ]; }

# fm_machine_get FIELD — echo one field from the card.
#
# Fails when the card is missing, unparseable, or lacks the field, so a caller
# that substitutes the output cannot silently proceed on an empty string.
fm_machine_get() {
  local field="$1" file value
  file="$(fm_machine_file)"
  [ -f "$file" ] || { fm_err "no machine identity card at $file — run 'fm machine init'"; return 1; }
  fm_require_cmd jq || return 1
  value="$(jq -er --arg f "$field" '.[$f] // empty' "$file" 2>/dev/null)" || {
    fm_err "machine card has no '$field': $file"
    return 1
  }
  printf '%s\n' "$value"
}

# fm_machine_get_opt FIELD — echo an optional field, or nothing when it is absent.
#
# Separate from fm_machine_get rather than a flag on it, so that the common case
# stays loud: every required field must fail when missing, and only a field the
# schema marks optional may quietly return empty. A caller reaching for this on a
# required field is saying something it does not mean.
fm_machine_get_opt() {
  local field="$1" file
  file="$(fm_machine_file)"
  [ -f "$file" ] || return 0
  fm_has_cmd jq || return 0
  jq -r --arg f "$field" '.[$f] // empty' "$file" 2>/dev/null || true
}

# fm_machine_workload — echo this machine's workload, empty when it has none.
#
# Empty is a real answer, not a failure: a workstation and a laptop run no
# bridge. A caller that needs one must say so itself, because "which profile"
# and "is there a profile at all" are different questions.
fm_machine_workload() { fm_machine_get_opt workload; }

# fm_machine_namespace [NAME] — echo the ROS namespace derived from a machine
# name, defaulting to this machine's.
#
# Derived, never typed. A namespace that is written down separately drifts from
# the hostname the moment someone renames a rig, and the two disagreeing is
# invisible until a topic lands nowhere. Hyphens become underscores because a
# ROS name may not contain a hyphen: fm-rec-01 → fm_rec_01.
fm_machine_namespace() {
  local name="${1:-}"
  [ -n "$name" ] || name="$(fm_machine_get name)" || return 1
  printf '%s\n' "${name//-/_}"
}

# Echo the workspace directory every First Motive checkout on this machine lives
# under: the card's `workspace` when the machine has a card, the manifest default
# otherwise.
#
# Falling back rather than failing, unlike fm_machine_get, because this is the
# answer to "where do checkouts go" and the loudest caller is a provisioning run
# that has to put a checkout somewhere before `machine init` has ever run. The
# fallback and the card's default are the same value, so the answer only differs
# on a machine that deliberately chose another workspace — and that machine has a
# card by definition.
#
# jq is checked rather than assumed: this is read during the curl bootstrap, on a
# host where base-deps has not installed jq yet.
fm_machine_workspace() {
  local ws=""
  if fm_machine_exists && fm_has_cmd jq; then
    ws="$(fm_machine_get workspace 2>/dev/null || true)"
  fi
  [ -n "$ws" ] || ws="${FM_MACHINE_WORKSPACE_DEFAULT:-$HOME/fm}"
  printf '%s\n' "$ws"
}

# Echo where this repo's own checkout belongs on a provisioned machine.
#
# Under the card's workspace, beside every other First Motive checkout, and named
# exactly `fm-setup`. The name is not cosmetic: fm-tools resolves every repo it
# knows about as <workspace>/<local_dir>, so a checkout kept anywhere else is one
# `fm doctor` reports as "fm-setup not cloned" on a machine this repo provisioned
# itself — the false alarm that taught everyone to ignore a red line in doctor.
# It lived in ~/.first-motive, outside the workspace entirely, which is exactly
# that case.
fm_setup_dir() {
  printf '%s/%s\n' "$(fm_machine_workspace)" "${FM_SETUP_CHECKOUT_NAME:-fm-setup}"
}

# Field validators, here rather than in the writer, because two callers now
# produce cards: `machine init` on a running host and `flash` into a cloud-init
# seed. A second copy of these rules would let the two disagree about what a
# valid card is, and the flash path is the one nobody can correct afterwards —
# an unvalidated value reaches the rig baked into /etc/fm/machine.json.
#
# Each rejects loudly with the value it refused. They mirror
# templates/machine/machine.schema.json; change the two together.

fm_machine_valid_role() {
  _fm_in_list "$1" ${FM_MACHINE_ROLES[@]+"${FM_MACHINE_ROLES[@]}"} ||
    { fm_err "invalid role: '$1' (expected one of: ${FM_MACHINE_ROLES[*]})"; return 1; }
}

fm_machine_valid_transport() {
  _fm_in_list "$1" ${FM_MACHINE_TRANSPORTS[@]+"${FM_MACHINE_TRANSPORTS[@]}"} ||
    { fm_err "invalid transport: '$1' (expected one of: ${FM_MACHINE_TRANSPORTS[*]})"; return 1; }
}

fm_machine_valid_fleet() {
  # LC_ALL=C, because a glob range is collation-dependent: under en_ZA.UTF-8 the
  # range a-z also matches uppercase, so `*[!a-z0-9-]*` accepted "Prod" and wrote
  # it to the card. The C locale gives the ASCII range the pattern is written to
  # mean. bash 3.2 on macOS has no globasciiranges to lean on instead.
  local LC_ALL=C
  case "$1" in
    *[!a-z0-9-]*|"") fm_err "invalid fleet: '$1' (lowercase letters, digits, hyphens)"; return 1 ;;
    [!a-z]*)         fm_err "invalid fleet: '$1' (must start with a lowercase letter)"; return 1 ;;
  esac
}

fm_machine_valid_workspace() {
  case "$1" in
    /*) ;;
    *) fm_err "invalid workspace: '$1' (must be an absolute path)"; return 1 ;;
  esac
}

# fm_machine_workload_value RAW — echo what a --workload flag value means.
#
# `none` is spelled out because an empty flag value cannot be told apart from a
# flag nobody passed, and without a spelling for "clear it" a machine repurposed
# from recorder to workstation would carry its old workload forever. Both
# writers normalise through here, so `none` means the same thing at
# `machine init` as it does at `flash`.
fm_machine_workload_value() {
  case "$1" in
    none) printf '' ;;
    *)    printf '%s' "$1" ;;
  esac
}

# Empty passes: workload is the one optional field, and "this machine runs no
# bridge" is a valid card rather than an omission to correct. Callers pass the
# value after fm_machine_workload_value, which is why `none` is named in the
# message — it is what a person types, and both writers accept it.
fm_machine_valid_workload() {
  [ -z "$1" ] && return 0
  _fm_in_list "$1" ${FM_MACHINE_WORKLOADS[@]+"${FM_MACHINE_WORKLOADS[@]}"} ||
    { fm_err "invalid workload: '$1' (expected one of: ${FM_MACHINE_WORKLOADS[*]}, or none)"; return 1; }
}

# fm_machine_valid_name NAME [ROLE] — check the name's shape, and when a role is
# given, that the name's abbreviation is that role's.
#
# The abbreviation is part of the name for a reason: a card claiming to be a
# jetson while calling itself fm-ws-01 puts a recorder's topics under the
# workstation's namespace, which is invisible until nothing subscribes.
fm_machine_valid_name() {
  # LC_ALL=C for the same reason as fm_machine_valid_fleet: the ranges below are
  # meant as ASCII, and a UTF-8 collation quietly widens them to match uppercase.
  local LC_ALL=C
  local name="$1" role="${2:-}" abbrev part
  # The abbreviation is extracted and checked for stray characters rather than
  # matched with a single glob. A glob cannot express "one or more letters" —
  # `fm-[a-z]*-[0-9][0-9]` lets the `*` swallow anything at all, so `fm-r1-01`
  # would pass here and then fail the schema, which is exactly the kind of
  # disagreement between the two copies of this contract that they must not have.
  case "$name" in
    fm-*-[0-9][0-9]) part="${name#fm-}"; part="${part%-*}" ;;
    *) fm_err "invalid name: '$name' (expected fm-<abbrev>-<nn>, e.g. fm-rec-01)"; return 1 ;;
  esac
  case "$part" in
    ""|*[!a-z]*) fm_err "invalid name: '$name' (the abbreviation must be lowercase letters only)"; return 1 ;;
  esac
  [ -n "$role" ] || return 0
  abbrev="$(fm_machine_abbrev "$role")" || return 1
  case "$name" in
    "fm-$abbrev-"*) ;;
    *) fm_err "name '$name' does not match role '$role' (expected fm-$abbrev-<nn>)"; return 1 ;;
  esac
}

# fm_machine_abbrev ROLE — echo the name abbreviation a role uses (jetson→rec).
fm_machine_abbrev() {
  local role="$1" entry r a
  for entry in ${FM_MACHINE_NAME_ABBREV[@]+"${FM_MACHINE_NAME_ABBREV[@]}"}; do
    IFS='|' read -r r a <<<"$entry"
    [ "$r" = "$role" ] && { printf '%s\n' "$a"; return 0; }
  done
  fm_err "no name abbreviation for role '$role' — add one to the manifest"
  return 1
}

# --- Accounts --------------------------------------------------------------

# fm_group_members GROUP — echo every member of GROUP, one per line, sorted.
#
# /etc/group lists secondary members only. Anyone whose *primary* group is GROUP
# is just as much a member and appears nowhere in that field, so the passwd
# table is read for a matching gid as well. Reading only /etc/group silently
# misses those accounts.
fm_group_members() {
  local group="$1" gid
  gid="$(getent group "$group" 2>/dev/null | cut -d: -f3)"
  [ -n "$gid" ] || return 0
  {
    getent group "$group" | cut -d: -f4 | tr ',' '\n'
    getent passwd | awk -F: -v gid="$gid" '$4 == gid { print $1 }'
  } | grep -v '^$' | sort -u
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

# fm_role_codename ROLE — echo the Ubuntu codename the role is built for.
# Same shape as fm_steps_for: the role→manifest mapping stays in one place.
fm_role_codename() {
  local role="$1"
  case "$role" in
    workstation) printf '%s\n' "${FM_OS_CODENAME_WORKSTATION:-}" ;;
    jetson)      printf '%s\n' "${FM_OS_CODENAME_JETSON:-}" ;;
    *) fm_err "unknown role: $role (use workstation|jetson)"; return 1 ;;
  esac
}
# fm_require_role_os ROLE [STRICT] — refuse a role the running OS cannot satisfy.
#
# Role detection sees a Tegra marker and nothing else, so any non-Jetson Linux
# box calls itself a workstation regardless of its Ubuntu. Provisioning then gets
# far enough to add an apt source before failing on packages that do not exist
# for this release, which leaves a half-built machine and a confusing error.
#
# STRICT=1 (an install or uninstall) aborts. Anything else — a --check — warns
# and carries on, because reading the state of a machine you are about to
# re-image is a reasonable thing to do.
#
# FM_ALLOW_OS_MISMATCH=1 overrides it. Container rehearsal needs no override, as
# each role is rehearsed on its own distro image.
fm_require_role_os() {
  local role="$1" strict="${2:-0}" want have
  want="$(fm_role_codename "$role")" || return 1
  have="$(fm_os_codename)"

  # A missing value is not a pass. About to change the machine, an unanswerable
  # check is a reason to stop: both of these end in apt failing a few steps later
  # anyway, and stopping here says why.
  if [ -z "$want" ]; then
    if [ "$strict" = "1" ]; then
      fm_err "no target OS pinned for role '$role' — add FM_OS_CODENAME_* to the manifest"
      return 1
    fi
    fm_warn "no target OS pinned for role '$role' — add one to the manifest"
    return 0
  fi

  # Empty means this host is not Ubuntu at all: another Linux with no
  # VERSION_CODENAME, or not Linux. Every step here installs Ubuntu packages.
  if [ -z "$have" ]; then
    if [ "$strict" = "1" ]; then
      fm_err "this host is not an Ubuntu release fm-setup can provision"
      fm_err "  role '$role' targets Ubuntu $want; no VERSION_CODENAME was readable here"
      fm_err "  set FM_ALLOW_OS_MISMATCH=1 to override"
      return 1
    fi
    fm_warn "no Ubuntu codename readable here — cannot check '$role' against $want"
    return 0
  fi

  [ "$have" = "$want" ] && return 0

  if [ "${FM_ALLOW_OS_MISMATCH:-0}" = "1" ]; then
    fm_warn "role '$role' targets $want, this host is $have — continuing (FM_ALLOW_OS_MISMATCH=1)"
    return 0
  fi
  if [ "$strict" != "1" ]; then
    fm_warn "role '$role' targets $want, this host is $have — reporting anyway"
    return 0
  fi

  fm_err "role '$role' targets Ubuntu $want, but this host is $have"
  fm_err "  provisioning would add an apt source and then fail on packages built for $want"
  fm_err "  re-image first, pick the other role, or set FM_ALLOW_OS_MISMATCH=1 to override"
  return 1
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
