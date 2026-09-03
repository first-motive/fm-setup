#!/usr/bin/env bash
#
# update.sh — converge this machine onto the checkout as it now stands.
#
#   scripts/update.sh            provision this host's role, non-interactively
#   scripts/update.sh --check    report what a converge would find, change nothing
#
# The repo-owned update entry point, in the same place and with the same
# contract as fm_ros2's. Two callers use it and neither of them is a person:
#
#   fm update                    after a clean pull, per the fm-tools registry
#   the appliance update timer    after checking this repo out onto a newer tag
#
# It exists so that neither caller has to know how fm-setup provisions. A timer
# that hardcoded `install.sh --jetson` would be a second place the role of a
# machine is written down, and the identity card exists precisely to delete
# those: the role is read from the card here, once, and the caller says only
# "converge".
#
# Non-interactive by construction. This runs unattended on a rig nobody is
# looking at, so NONINTERACTIVE is set and the prompting steps auto-decline —
# a security-sensitive step that would have asked is skipped rather than
# answered on someone's behalf.
#
# Not idempotent in the sense of "does nothing" — it re-runs every step. Each
# step is idempotent, which is the property that matters: a converge on an
# already-current machine reports state and changes nothing.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$_here/.." && pwd)"
# shellcheck source=../lib.sh disable=SC1091
. "$FM_ROOT/lib.sh"
# shellcheck source=manifest.sh disable=SC1091
. "$FM_ROOT/scripts/manifest.sh"

usage() {
  cat <<'EOF'
update.sh — converge this machine onto this checkout

Usage: scripts/update.sh [--check]

  (no args)   run this host's role installer, non-interactively
  --check     report each step's state and change nothing
EOF
}

# Echo the install.sh flag for this host's role.
#
# The card is asked first and the hardware second, which is the same order every
# other reader uses: a card is what the machine says it is, and hardware
# detection is the fallback for a host that has not been given one yet. A `mac`
# card is refused outright rather than detected around — fm-setup provisions no
# macOS machine, and converging one would mean running the Linux steps on it.
role_flag() {
  local role=""
  if fm_machine_exists && fm_has_cmd jq; then
    role="$(fm_machine_get role 2>/dev/null || true)"
    # A card that exists and cannot be read is a different situation from no card
    # at all, and the silent fallback hid exactly that: a malformed card sent a
    # Jetson down the workstation path with nothing said about why.
    [ -n "$role" ] || fm_warn "machine card at $(fm_machine_file) is unreadable — falling back to hardware detection"
  fi
  [ -n "$role" ] || role="$(fm_detect_role)"
  case "$role" in
    workstation|jetson|trainer) printf -- '--%s\n' "$role" ;;
    mac) fm_err "this machine's card says role 'mac' — fm-setup provisions no macOS host"; return 1 ;;
    *) fm_err "unknown role '$role' — fix the card with 'fm machine init'"; return 1 ;;
  esac
}

main() {
  local mode="install" flag
  case "${1:-}" in
    "")        ;;
    --check)   mode="check" ;;
    -h|--help) usage; return 0 ;;
    *)         fm_err "unknown option: $1"; usage >&2; return 1 ;;
  esac

  flag="$(role_flag)" || return 1
  fm_log "converging fm-setup ($flag, $mode) from $FM_ROOT"

  if [ "$mode" = "check" ]; then
    bash "$FM_ROOT/install.sh" "$flag" --check
    return 0
  fi
  NONINTERACTIVE=1 bash "$FM_ROOT/install.sh" "$flag" --yes
}

main "$@"
