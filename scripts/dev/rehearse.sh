#!/usr/bin/env bash
#
# rehearse — run a role's package steps inside a container of its target distro.
#
#   ./scripts/dev/rehearse.sh              both roles
#   ./scripts/dev/rehearse.sh jetson       one role
#   ./scripts/dev/rehearse.sh --steps base-deps,ros2 workstation
#
# Provisioning is the one thing this repo cannot test on the machine that writes
# it: the workstation runs Ubuntu 26.04 and the Jetson runs 22.04 on aarch64,
# and neither is a laptop. A container is not a machine — no systemd, no
# devices, no GPU — but it is a real apt tree of the real release, which is
# enough to prove the part that actually breaks: repo setup, package names, and
# whether a step's control flow survives to the end.
#
# This found the RETURN-trap leak in 40-ros2.sh that aborted a run after ROS
# installed, with every later step silently skipped.
#
# Steps that need systemd, hardware, or a GPU are excluded by default. Pass
# --steps to widen it and expect failures that mean nothing.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$_here/../.." && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$FM_ROOT/lib.sh"

# role|image|platform. Both run native on Apple silicon; amd64 would emulate,
# and the packages under test are arch-independent in every way that matters
# here.
REHEARSALS=(
  "jetson|ubuntu:22.04|linux/arm64"
  "workstation|ubuntu:26.04|linux/arm64"
)

# Steps whose failure inside a container would mean nothing: docker needs a
# daemon, tailscale and udev need the host, isaac-sim needs a GPU, users and
# agent-ruleset need real accounts.
DEFAULT_STEPS="base-deps,fm-cli,ros2"

usage() {
  cat <<'EOF'
rehearse — run a role's package steps in a container of its target distro

Usage: ./scripts/dev/rehearse.sh [options] [role...]

  role            workstation | jetson   (default: both)

Options:
  --steps a,b,c   step ids to run (default: base-deps,ros2)
  --keep          leave the container running for inspection
  -h, --help      show this help

Needs a working docker daemon. Nothing here touches this machine.
EOF
}

# rehearse ROLE IMAGE PLATFORM STEPS — returns non-zero if the run fails.
rehearse() {
  local role="$1" image="$2" platform="$3" steps="$4" keep="$5"
  local rm_flag="--rm"
  [ "$keep" = "1" ] && rm_flag=""

  fm_log "$role — $image ($platform), steps: $steps"

  # The sudo shim is `env`, not a bare exec: steps call
  # `sudo DEBIAN_FRONTEND=noninteractive apt-get …`, and a shim that cannot take
  # VAR=value prefixes fails in a way that looks like a step bug.
  docker run $rm_flag --platform "$platform" \
    -v "$FM_ROOT:/fm-setup:ro" \
    -e DEBIAN_FRONTEND=noninteractive \
    -e NONINTERACTIVE=1 \
    -e FM_NO_MODIFY_PATH=1 \
    "$image" bash -c '
      set -euo pipefail
      # Refuse to install the shim anywhere but a container: it replaces sudo
      # with a no-op, which on a real machine would be a working privilege
      # escalation left on disk.
      [ -e /.dockerenv ] || { echo "not in a container — refusing to shim sudo" >&2; exit 1; }
      printf "#!/bin/sh\nexec env \"\$@\"\n" > /usr/local/bin/sudo
      chmod +x /usr/local/bin/sudo
      apt-get update -qq >/dev/null 2>&1
      bash /fm-setup/install.sh --'"$role"' --only '"$steps"' -y
    '
}

main() {
  local steps="$DEFAULT_STEPS" keep=0 roles=()

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --steps)   steps="${2:-}"; shift 2 ;;
      --keep)    keep=1; shift ;;
      -h|--help) usage; return 0 ;;
      workstation|jetson) roles+=("$1"); shift ;;
      *) fm_err "unknown argument: $1"; usage; return 1 ;;
    esac
  done

  # $steps is interpolated into a `bash -c` string that runs in the container,
  # so an unchecked value is command injection: `--steps 'x; rm -rf /'` would
  # run inside the container as root. Step ids are lowercase words, digits, and
  # hyphens, separated by commas — nothing else has any business here.
  case "$steps" in
    ""|*[!a-z0-9,-]*)
      fm_err "invalid --steps value: '$steps' (expected comma-separated step ids)"
      return 1 ;;
  esac

  fm_has_docker || { fm_err "docker is not reachable — start it and retry"; return 1; }

  local entry role image platform failed=()
  for entry in "${REHEARSALS[@]}"; do
    IFS='|' read -r role image platform <<<"$entry"
    if [ "${#roles[@]}" -gt 0 ] && ! printf '%s\n' "${roles[@]}" | grep -qx "$role"; then
      continue
    fi
    if rehearse "$role" "$image" "$platform" "$steps" "$keep"; then
      fm_ok "$role rehearsal passed"
    else
      fm_err "$role rehearsal failed"
      failed+=("$role")
    fi
    echo
  done

  if [ "${#failed[@]}" -gt 0 ]; then
    fm_err "failed: ${failed[*]}"
    return 1
  fi
  fm_ok "every rehearsal passed."
}

main "$@"
