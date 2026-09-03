#!/usr/bin/env bash
#
# converge-check.sh — run the entry point the appliance timer runs, in a container.
#
#   ./scripts/dev/converge-check.sh              every role
#   ./scripts/dev/converge-check.sh jetson       one role
#
# `scripts/update.sh` is what fm_ros2's appliance-update timer executes, as root,
# on every rig, the moment this repo's newest `v*` tag moves. Until this script
# existed nothing ran it: CI shellchecked it, and `rehearse` covers
# `install.sh --only base-deps,fm-cli,ros2`, which is a different entry point and
# three of the fourteen steps.
#
# That gap has a specific shape. A tag cut is the one action here with no undo —
# it reaches every rig unattended — and the check that would have caught a
# mistake in the path it triggers was the one check nobody had written.
#
# What this proves, per role:
#
#   1. update.sh resolves the role from the identity card, and falls back to
#      hardware detection when a machine has no card yet
#   2. it dispatches to install.sh with the matching flag
#   3. install.sh --check reports on every step without changing anything
#
# `--check` is read-only, which is why this can cover all fourteen steps where a
# rehearsal can only afford three.
#
# Needs a working docker daemon. Nothing here touches this machine.
set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$_here/../.." && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$FM_ROOT/lib.sh"

# Same image and platform defaults as rehearse.sh, for the same reason: the
# target distro is what a rig runs, and Apple silicon runs arm64 natively.
IMAGE="${FM_CONVERGE_IMAGE:-ubuntu:22.04}"
PLATFORM="${FM_REHEARSE_PLATFORM:-linux/arm64}"

usage() {
  cat <<'EOF'
converge-check.sh — run scripts/update.sh --check in a container of the target distro

Usage: ./scripts/dev/converge-check.sh [role...]

  role   workstation | jetson | trainer   (default: all)

Env: FM_CONVERGE_IMAGE, FM_REHEARSE_PLATFORM
EOF
}

# converge_check ROLE — non-zero if the converge entry point fails for that role.
converge_check() {
  local role="$1"

  fm_log "$role — $IMAGE ($PLATFORM), scripts/update.sh --check"

  docker run --rm --platform "$PLATFORM" \
    -v "$FM_ROOT:/fm-setup:ro" \
    -e DEBIAN_FRONTEND=noninteractive \
    -e NONINTERACTIVE=1 \
    -e FM_NO_MODIFY_PATH=1 \
    -e FM_MACHINE_FILE=/tmp/machine.json \
    "$IMAGE" bash -c '
      set -euo pipefail
      # Same refusal as rehearse.sh: a no-op sudo left on a real machine is a
      # working privilege escalation.
      [ -e /.dockerenv ] || { echo "not in a container — refusing to shim sudo" >&2; exit 1; }
      printf "#!/bin/sh\nexec env \"\$@\"\n" > /usr/local/bin/sudo
      chmod +x /usr/local/bin/sudo
      apt-get update -qq >/dev/null 2>&1
      apt-get install -y -qq jq >/dev/null 2>&1

      role='"$role"'

      # A machine with a card: the card decides, and the card is what every rig
      # has once `fm machine init` has run on it.
      printf "{\"role\":\"%s\"}\n" "$role" > /tmp/machine.json
      out="$(bash /fm-setup/scripts/update.sh --check)"
      printf "%s\n" "$out"
      printf "%s" "$out" | grep -q -- "--$role" \
        || { echo "FAIL: carded $role did not dispatch to install.sh --$role" >&2; exit 1; }

      # A machine with no card yet: detection is the fallback, and it must still
      # reach a role rather than failing the converge.
      rm -f /tmp/machine.json
      bash /fm-setup/scripts/update.sh --check >/dev/null \
        || { echo "FAIL: uncarded machine could not resolve a role" >&2; exit 1; }

      echo "converge check ok: $role"
    '
}

main() {
  local roles=()

  case "${1:-}" in
    -h|--help) usage; return 0 ;;
  esac
  while [ $# -gt 0 ]; do
    case "$1" in
      workstation|jetson|trainer) roles+=("$1") ;;
      *) fm_err "unknown role: $1"; usage >&2; return 1 ;;
    esac
    shift
  done
  [ ${#roles[@]} -gt 0 ] || roles=(workstation jetson trainer)

  fm_require_cmd docker

  local role rc=0
  for role in "${roles[@]}"; do
    converge_check "$role" || rc=1
  done

  [ "$rc" -eq 0 ] && fm_ok "converge entry point ok for: ${roles[*]}"
  return "$rc"
}

main "$@"
