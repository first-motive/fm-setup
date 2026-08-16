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

# Load lib.sh from the checkout beside this script.
#
# There is deliberately no pipe path here, unlike install.sh. Every verb is a
# script under scripts/run/, so a piped run.sh has nothing to dispatch to even
# once lib.sh is in memory — the fetch only ever bought a prettier error
# message, and it needed its own copy of the release tag to fetch from. That
# copy was the second of the four places the tag was hand-synced, kept alive
# solely for a message this function can print without it.
fm_load_lib() {
  local here
  here="$(fm_script_dir)" || here=""
  if [ -z "$here" ] || [ ! -f "$here/lib.sh" ]; then
    echo "run.sh needs a checkout — provision with install.sh first, then run it from there" >&2
    exit 1
  fi
  # shellcheck source=lib.sh disable=SC1091
  . "$here/lib.sh"
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
  # fm_load_lib already refused a run without one, so this cannot fail here.
  here="$(fm_script_dir)"
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
