#!/usr/bin/env bash
#
# install.sh — fm-setup's provisioning front door.
#
# Provisions a First Motive machine from a role manifest. Every step is
# idempotent, so a re-run converges rather than duplicating.
#
#   ./install.sh --workstation            provision the GPU workstation
#   ./install.sh --jetson                 provision the Jetson capture rig
#   ./install.sh --workstation --check    report state, change nothing
#   ./install.sh --workstation --list     list the role's steps
#   ./install.sh uninstall --jetson       reverse what is reversible
#
# Bootstrap a fresh machine (a release tag, never a branch):
#
#   curl -fsSL https://raw.githubusercontent.com/first-motive/fm-setup/v0.1.8/install.sh | bash -s -- --workstation
#
# Inspect before running — the honest path, because a piped script verifies
# everything except itself:
#
#   curl -fsSL https://raw.githubusercontent.com/first-motive/fm-setup/v0.1.8/install.sh -o install.sh
#   less install.sh && bash install.sh --workstation
#
# For an unattended machine, fetch by commit rather than by tag. A tag is a name
# and can be moved; a commit sha cannot. See the README for the current values.
#
# Env overrides:
#   FM_SETUP_DIR        where the curl path clones this repo  (default: $HOME/.first-motive/fm-setup)
#   FM_LIB_SHA256       expected sha256 of a fetched lib.sh   (set it for unattended installs)
#   FM_SETUP_SHA        commit the checkout must be at        (verifies every step script)
#   FM_NO_MODIFY_PATH   skip shell-profile edits              (set to 1 in CI)
#   FM_SELFTEST         CI self-test, provisions nothing      (set to 1 in CI)
#   NONINTERACTIVE      never prompt; security-sensitive steps auto-decline
#   FM_ALLOW_OS_MISMATCH  provision a role on an Ubuntu it does not target
#
# The body is wrapped in main() and called on the last line, so a truncated
# `curl | bash` leaves an incomplete function that never runs.

set -euo pipefail

FM_REPO="${FM_REPO:-first-motive/fm-setup}"
# A release tag, not a branch: what provisioned a machine has to stay nameable
# months later. Bump this in the same commit that cuts a new tag, so the script
# a tag ships fetches its own lib.sh rather than a newer one.
#
# This assignment is the repo's single source for the release tag. run.sh and
# the flash seed read it back through lib.sh's fm_release_tag, and the README's
# copy-paste lines and this file's own header examples are rewritten from it by
# `scripts/dev/release-tag.sh --set`, which CI re-checks on every pull request.
# Bump it with that command rather than by hand: the value has to appear
# literally here, because a piped install.sh has no checkout to read it from,
# and it should appear literally nowhere else.
FM_TAG="${FM_TAG:-v0.1.8}"
# Overridable so the curl-pipe path can be exercised against a local checkout —
# CI points it at a file:// URL and tests the real code path without a network.
FM_RAW_BASE="${FM_RAW_BASE:-https://raw.githubusercontent.com/${FM_REPO}/${FM_TAG}}"
FM_GIT_URL="${FM_GIT_URL:-https://github.com/${FM_REPO}.git}"

FM_SETUP_DIR="${FM_SETUP_DIR:-$HOME/.first-motive/fm-setup}"
FM_SELFTEST="${FM_SELFTEST:-0}"

# Exported so every step sees the same answer: steps that would touch a shell
# profile check FM_NO_MODIFY_PATH, and prompting steps check NONINTERACTIVE.
export FM_NO_MODIFY_PATH="${FM_NO_MODIFY_PATH:-0}"
export NONINTERACTIVE="${NONINTERACTIVE:-0}"

# Resolve this script's own directory, following symlinks. Fails when the script
# arrived over a pipe, which is how the curl path is detected.
#
# The test is whether BASH_SOURCE[0] names a file that exists, not whether it is
# non-empty. Bash 3.2 leaves it empty for a script read from stdin, but bash 5
# sets it to a non-path placeholder — so an emptiness test passes there, the
# script resolves itself from the working directory, and the fetch, the checksum
# gate, and the clone are all silently skipped on the exact platform this
# provisions. CI on bash 5 is what caught it.
fm_script_dir() {
  local source="${BASH_SOURCE[0]:-}" dir
  [ -n "$source" ] && [ -f "$source" ] || return 1
  while [ -L "$source" ]; do
    dir="$(cd -P "$(dirname "$source")" && pwd)"
    source="$(readlink "$source")"
    case "$source" in /*) ;; *) source="$dir/$source" ;; esac
  done
  cd -P "$(dirname "$source")" && pwd
}

# Load lib.sh. From a checkout it sits next to this script. Over a curl pipe
# there is nothing on disk, so download it to a temp file first.
#
# Downloading rather than eval'ing the response directly is what makes the
# checksum gate possible: everything in lib.sh runs in this shell, and this shell
# goes on to run apt and write to /etc. Set FM_LIB_SHA256 to the sha256 published
# with the release and a tampered or truncated lib.sh aborts the install instead
# of executing. Without it the load still trusts TLS and the repo, so pin the
# checksum for anything unattended.
fm_load_lib() {
  local here lib tmp actual
  if here="$(fm_script_dir 2>/dev/null)" && lib="$here/lib.sh" && [ -f "$lib" ]; then
    # shellcheck source=lib.sh disable=SC1091
    . "$lib"
    return 0
  fi

  tmp="$(mktemp)"
  curl -fsSL "$FM_RAW_BASE/lib.sh" -o "$tmp" || {
    echo "failed to fetch lib.sh from $FM_RAW_BASE" >&2
    rm -f "$tmp"
    exit 1
  }
  if [ -n "${FM_LIB_SHA256:-}" ]; then
    if command -v sha256sum >/dev/null 2>&1; then
      actual="$(sha256sum "$tmp" | cut -d' ' -f1)"
    else
      actual="$(shasum -a 256 "$tmp" | cut -d' ' -f1)"
    fi
    if [ "$actual" != "$FM_LIB_SHA256" ]; then
      echo "lib.sh checksum mismatch: expected $FM_LIB_SHA256, got $actual" >&2
      rm -f "$tmp"
      exit 1
    fi
  fi
  # shellcheck disable=SC1090
  . "$tmp"
  rm -f "$tmp"
}

usage() {
  cat <<'EOF'
install.sh — provision a First Motive machine

Usage: ./install.sh [install|uninstall] [options]

  install      run the role's steps (default)
  uninstall    reverse the role's steps, in reverse order

Role (default: detected from the hardware):
  --workstation     Ubuntu 26.04 GPU box — training, annotation, sim
  --jetson          Ubuntu 22.04 Jetson Orin Nano — capture rig

Options:
  --check           report each step's state, change nothing
  --list            list the role's steps, then exit
  --only  a,b,c     run only these step ids
  --skip  a,b,c     run every step except these ids
  --dry-run         print what would run, change nothing
  -y, --yes         non-interactive; prompts auto-decline (CI mode)
  -h, --help        show this help

Env: FM_SETUP_DIR, FM_NO_MODIFY_PATH, FM_SELFTEST, NONINTERACTIVE,
     FM_ALLOW_OS_MISMATCH
     (see the header comment)
EOF
}

# The curl path has no checkout, so clone one and hand over to it. Everything
# below the front door — the manifest, the steps — lives in the repo, and a
# provisioned machine needs that checkout on disk anyway to re-run or re-check.
fm_bootstrap_checkout() {
  # A branch moves; what provisioned this machine should be nameable later.
  case "$FM_TAG" in
    v*) ;;
    *) fm_warn "FM_TAG='$FM_TAG' is a moving ref — pin a release tag for a reproducible install" ;;
  esac
  fm_require_cmd git || {
    fm_err "git is required to bootstrap; install it with 'sudo apt-get install -y git'"
    return 1
  }
  local cloned_now=0
  if [ -d "$FM_SETUP_DIR/.git" ]; then
    fm_log "updating checkout at $FM_SETUP_DIR"
    git -C "$FM_SETUP_DIR" fetch --quiet --tags origin
    git -C "$FM_SETUP_DIR" checkout --quiet "$FM_TAG"
    git -C "$FM_SETUP_DIR" pull --quiet --ff-only origin "$FM_TAG" 2>/dev/null || true
  else
    fm_log "cloning $FM_REPO into $FM_SETUP_DIR"
    mkdir -p "$(dirname "$FM_SETUP_DIR")"
    git clone --quiet --branch "$FM_TAG" "$FM_GIT_URL" "$FM_SETUP_DIR"
    cloned_now=1
  fi

  # A tag is a name, and a name can be moved by anyone who can push. A commit is
  # its content. Pin FM_SETUP_SHA and the checkout is verified against something
  # nobody can rewrite — which covers every step script at once, not just the
  # one file the checksum gate sees.
  if [ -n "${FM_SETUP_SHA:-}" ]; then
    local head
    head="$(git -C "$FM_SETUP_DIR" rev-parse HEAD)"
    if [ "$head" != "$FM_SETUP_SHA" ]; then
      fm_err "checkout is not the pinned commit"
      fm_err "  expected $FM_SETUP_SHA"
      fm_err "  actual   $head"
      fm_err "refusing to provision from it — the tag may have been moved"
      # Leaving it behind would put an unverified tree exactly where the next
      # run looks for a checkout to update and trust. Only what this run cloned
      # is removed: a checkout that was already there is the operator's, and
      # deleting their work to report an error would be the worse failure.
      if [ "$cloned_now" = "1" ]; then
        rm -rf "$FM_SETUP_DIR"
        fm_info "removed the unverified checkout at $FM_SETUP_DIR"
      else
        fm_warn "the pre-existing checkout at $FM_SETUP_DIR is left as it was — inspect it before reusing it"
      fi
      return 1
    fi
    fm_ok "checkout verified at $FM_SETUP_SHA"
  fi

  fm_ok "checkout ready at $FM_SETUP_DIR"
}

# Run --list and a dry-run install for both roles. Proves the script survives the
# curl-pipe path, and that every manifest entry resolves to a real step file,
# without provisioning anything. CI sets FM_SELFTEST=1.
fm_selftest() {
  local here role id file missing=0
  here="$(fm_script_dir)"
  fm_log "self-test: manifest resolves, dry run for every role"
  for role in workstation jetson; do
    fm_list_steps "$role"
    while IFS='|' read -r id file _; do
      if [ ! -f "$here/scripts/steps/$file" ]; then
        fm_err "$role step '$id' points at a missing file: scripts/steps/$file"
        missing=1
      fi
    done < <(fm_steps_for "$role")
    fm_run_steps install "$role" "$here/scripts/steps" 1
  done
  [ "$missing" -eq 0 ] || return 1
  fm_ok "self-test passed."
}

main() {
  fm_load_lib
  fm_banner

  local cmd="install" role="" mode_flag="" list=0 dry=0
  # Kept verbatim for the curl path, which re-execs the cloned copy with the
  # arguments the user originally typed. Flag parsing below consumes "$@".
  local orig_args=("$@")

  while [ "$#" -gt 0 ]; do
    case "$1" in
      install|uninstall) cmd="$1"; shift ;;
      --workstation)     role="workstation"; shift ;;
      --jetson)          role="jetson"; shift ;;
      --check)           mode_flag="check"; shift ;;
      --list)            list=1; shift ;;
      --only)            fm_collect FM_ONLY "${2:-}"; shift 2 ;;
      --skip)            fm_collect FM_SKIP "${2:-}"; shift 2 ;;
      --dry-run)         dry=1; shift ;;
      -y|--yes)          NONINTERACTIVE=1; export NONINTERACTIVE; shift ;;
      -h|--help)         usage; return 0 ;;
      *) fm_err "unknown option: $1"; usage; return 1 ;;
    esac
  done

  local here
  if ! here="$(fm_script_dir 2>/dev/null)" || [ ! -d "$here/scripts/steps" ]; then
    fm_bootstrap_checkout
    exec bash "$FM_SETUP_DIR/install.sh" ${orig_args[@]+"${orig_args[@]}"}
  fi

  # shellcheck source=scripts/manifest.sh disable=SC1091
  . "$here/scripts/manifest.sh"

  if [ "$FM_SELFTEST" = "1" ]; then
    fm_selftest
    return 0
  fi

  [ -n "$role" ] || role="$(fm_detect_role)"

  if [ "$list" = "1" ]; then
    fm_list_steps "$role"
    return 0
  fi

  local mode="$cmd"
  [ -n "$mode_flag" ] && mode="$mode_flag"

  # After --list, which is documentation and works on any host, and before any
  # step runs. Strict only when this run would actually change the machine: a
  # --check reports state and a --dry-run prints a plan, and both are reasonable
  # things to do on a box that is waiting to be re-imaged.
  local strict=0
  case "$mode" in install|uninstall) [ "$dry" = "1" ] || strict=1 ;; esac
  fm_require_role_os "$role" "$strict" || return 1

  fm_log "fm-setup — $role [$mode]"
  fm_info "checkout: $here"
  [ "${NONINTERACTIVE:-0}" = "1" ] && fm_info "NONINTERACTIVE — prompts auto-decline"
  echo

  fm_run_steps "$mode" "$role" "$here/scripts/steps" "$dry"
  fm_ok "done."
}

main "$@"
