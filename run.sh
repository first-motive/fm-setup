#!/usr/bin/env bash
#
# run.sh — fm-setup's verb front door.
#
# install.sh provisions a machine. run.sh is for what you do afterwards: a thin,
# branded dispatcher over the verbs in scripts/run/, each runnable standalone.
#
#   ./run.sh check              report provisioning drift on this machine
#   ./run.sh --help
#
# The body is wrapped in main() and called on the last line, so a truncated pipe
# never half-runs.

set -euo pipefail

FM_REPO="${FM_REPO:-first-motive/fm-setup}"
FM_TAG="${FM_TAG:-v0.1.8}"
FM_RAW_BASE="${FM_RAW_BASE:-https://raw.githubusercontent.com/${FM_REPO}/${FM_TAG}}"
# Where install.sh puts the checkout, named in the error a piped run.sh prints.
FM_SETUP_DIR_HINT="${FM_SETUP_DIR:-$HOME/.first-motive/fm-setup}"

# Resolve this script's own directory, following symlinks, so scripts/run/<verb>
# is found regardless of the caller's working directory. Fails when this script
# arrived over a pipe.
#
# BASH_SOURCE[0] has to name a file that exists: bash 3.2 leaves it empty for a
# script read from stdin, bash 5 sets a non-path placeholder, and falling back
# to `pwd` on either would run whatever happens to sit in the caller's directory.
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

# Load lib.sh from the checkout, or download it when this script came over a
# pipe. Set FM_LIB_SHA256 to the checksum published with the release to gate the
# download — see install.sh for why the fetch is not eval'd directly.
fm_load_lib() {
  local here lib tmp actual
  if here="$(fm_script_dir)" && lib="$here/lib.sh" && [ -f "$lib" ]; then
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

# Reattach an interactive terminal after a curl pipe has consumed stdin.
#
# /dev/tty existing is not the same as /dev/tty being usable: in CI, in a cron
# job, and under a harness there is no controlling terminal, and opening it
# fails. Testing the open on a spare descriptor makes that case a no-op instead
# of killing the run before the verb starts.
reattach_tty() {
  [ -t 0 ] && return 0
  if { exec 3</dev/tty; } 2>/dev/null; then
    exec 0<&3 3<&-
  fi
}

usage() {
  cat <<'EOF'
run.sh — run an fm-setup verb

Usage: ./run.sh <verb> [args…]
       ./run.sh --help

Verbs live in scripts/run/ and are runnable standalone:
  ./run.sh check      ->  scripts/run/check.sh

  -h, --help   show this help

To provision a machine rather than inspect one, use ./install.sh.
EOF
}

main() {
  fm_load_lib
  fm_banner

  if [ "$#" -eq 0 ]; then
    usage
    return 1
  fi

  case "$1" in
    -h|--help) usage; return 0 ;;
  esac

  local verb="$1"; shift
  local here script
  if ! here="$(fm_script_dir)"; then
    # A verb is a script in the checkout, so there is nothing to dispatch to
    # when run.sh itself arrived over a pipe.
    fm_err "run.sh needs a checkout — provision first with install.sh, then run it from $FM_SETUP_DIR_HINT"
    return 1
  fi
  script="$here/scripts/run/$verb.sh"

  if [ ! -f "$script" ]; then
    fm_err "unknown verb: $verb"
    usage
    return 1
  fi

  reattach_tty
  bash "$script" "$@"
}

main "$@"
