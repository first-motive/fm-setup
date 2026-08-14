#!/usr/bin/env bash
#
# verify-rmw — prove a node can start under every RMW the manifest requires.
#
# Called by scripts/dev/rehearse.sh inside a container, and safe to run on a
# real host. Not a verb: it takes no arguments and nobody types it.
#
# Why this exists rather than a package check: apt is satisfied by any one RMW
# provider, so asking for Cyclone alongside ros-base lets it settle the
# dependency with Cyclone and never install FastDDS. Everything reports success.
# The shortfall appears later, when a node starts and exits with "failed to load
# shared library 'librmw_fastrtps_cpp.so'" — on a provisioned appliance, far
# from the change that caused it. A Jetson bring-up found it exactly that way.
#
# Starting a node is the assertion because it is the thing that broke. A dpkg
# check would pass on a package that installed but cannot load.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$_here/../.." && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$FM_ROOT/lib.sh"

# The required list arrives from the caller's environment when this runs in a
# container, where the manifest's arrays are not in scope; otherwise it is read
# from the manifest directly.
if [ -z "${FM_RMW_REQUIRED:-}" ]; then
  # shellcheck source=../manifest.sh disable=SC1091
  . "$FM_ROOT/scripts/manifest.sh"
  FM_RMW_REQUIRED="${FM_ROS_RMW_REQUIRED[*]}"
fi

# Echo the installed ROS distro, empty when none is present.
ros_distro_installed() {
  local d
  for d in /opt/ros/*/; do
    [ -f "$d/setup.bash" ] || continue
    basename "$d"
    return 0
  done
}

main() {
  local distro rmw failed=()

  distro="$(ros_distro_installed)"
  if [ -z "$distro" ]; then
    fm_skip "no ROS installation under /opt/ros — nothing to verify"
    return 0
  fi

  # setup.bash reads unset variables; errexit and nounset both have to stand
  # down for it, then come straight back.
  set +u
  # shellcheck disable=SC1090,SC1091
  . "/opt/ros/$distro/setup.bash"
  set -u

  fm_log "verifying every required RMW starts a node ($distro)"
  for rmw in $FM_RMW_REQUIRED; do
    if RMW_IMPLEMENTATION="$rmw" ros2 pkg list >/dev/null 2>&1; then
      fm_ok "$rmw"
    else
      fm_err "$rmw cannot start a node"
      failed+=("$rmw")
    fi
  done

  if [ "${#failed[@]}" -gt 0 ]; then
    fm_err "missing RMW support: ${failed[*]}"
    fm_info "add the matching ros-$distro-<rmw> package to the role's list in"
    fm_info "scripts/manifest.sh — apt will not pull it on its own"
    return 1
  fi
  fm_ok "every required RMW is usable"
}

main "$@"
