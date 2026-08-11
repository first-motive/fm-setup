#!/usr/bin/env bash
#
# check — report this machine's provisioning state, one line per step.
#
# Read-only by contract: every step's check mode reports and changes nothing, so
# this is safe to run on a live machine at any time. It answers "has this host
# drifted from its manifest?" without touching it.
#
#   ./run.sh check                  check the detected role
#   ./run.sh check --jetson         check a named role
#   ./run.sh check --only docker    check one step
#
# install.sh --check runs the same manifest walk through the provisioning door.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$_here/../.." && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$FM_ROOT/lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$FM_ROOT/scripts/manifest.sh"

usage() {
  cat <<'EOF'
check — report provisioning state, change nothing

Usage: ./run.sh check [options]

  --workstation | --jetson   role to check (default: detected)
  --only  a,b,c              check only these step ids
  --skip  a,b,c              check every step except these ids
  -h, --help                 show this help
EOF
}

main() {
  local role=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --workstation) role="workstation"; shift ;;
      --jetson)      role="jetson"; shift ;;
      --only)        fm_collect FM_ONLY "${2:-}"; shift 2 ;;
      --skip)        fm_collect FM_SKIP "${2:-}"; shift 2 ;;
      -h|--help)     usage; return 0 ;;
      *) fm_err "unknown option: $1"; usage; return 1 ;;
    esac
  done

  [ -n "$role" ] || role="$(fm_detect_role)"

  fm_log "fm-setup — $role [check]"
  echo
  fm_run_steps check "$role" "$FM_ROOT/scripts/steps"
}

main "$@"
