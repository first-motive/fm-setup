#!/usr/bin/env bash
# fm-render: rosdep-update sha256:f2b0d67d3661b1905f5126099f9c35fea8b23a014665ea60d6b5abec881c85e1 — rendered by the First Motive render plane — edit the upstream source, not this file
# `rosdep update`, made survivable.
#
#   ./rosdep-update.sh [distro]
#
# rosdep fetches its sources from raw.githubusercontent.com. Those fetches are
# unauthenticated, so they are rate limited, and rosdep exits non-zero when any one
# source fails. Under `set -e` — which every caller uses — one throttled file fails
# the whole build:
#
#   ERROR: unable to process source [.../rosdistro/master/releases/fuerte.yaml]:
#   	HTTP Error 429: Too Many Requests
#   ERROR: Not all sources were able to be updated.
#
# That happened repeatedly across fm-robot, fm-sim and fm-ros2 in one afternoon while
# GitHub was under strain, on changes that could not have caused it. Two fixes, in
# order of how much they help:
#
#   1. Stop fetching what we do not use. The failing source above is `gbpdistro`,
#      pointing at ROS 1 Fuerte — released 2012, end-of-life, and irrelevant to every
#      ROS2 package in this org. Dropping that line removes the failure outright
#      rather than retrying it.
#   2. Retry the rest. Rate limiting is transient by nature, and a second attempt a
#      few seconds later almost always succeeds. One attempt is a coin toss on a busy
#      day.
#
# Exits non-zero only when every attempt fails, so a genuinely broken rosdep still
# stops the build.
#
# Rendered into every repo that runs `rosdep update`, because the first version of
# this fix reached the CI workflows and the bootstrap preambles and not the machine
# layer — which is the one caller that runs unattended, on real hardware, where an
# abort leaves a rig provisioned halfway. One source, rendered, is what stops the
# next fix landing in three places out of four.
set -uo pipefail

DISTRO="${1:-${ROS_DISTRO:-humble}}"
ATTEMPTS="${ROSDEP_UPDATE_ATTEMPTS:-3}"
SOURCES_DIR="/etc/ros/rosdep/sources.list.d"

main() {
  # ROS 1 gbpdistro sources: nothing here consumes them, and they are the source that
  # actually fails. Comment rather than delete, so a `cat` of the file still explains
  # itself to whoever looks next.
  #
  # The sources live in /etc and are root-owned. In CI this runs as root and the
  # edit lands; on a rig it runs as the appliance user, where the first version of
  # this discarded its own failure and left the source in place while reporting
  # that it had dropped it. Escalate when escalation is available, and say so
  # plainly when it is not — an unfixable condition reported is worth more than a
  # fix that quietly did not happen.
  if [ -d "$SOURCES_DIR" ] && grep -rqs '^gbpdistro' "$SOURCES_DIR"; then
    local sed_cmd=(sed -i 's|^gbpdistro|# gbpdistro (ROS 1, unused here — see fm-tools#19) |')
    local ran=1
    if [ "$(id -u)" -eq 0 ]; then
      "${sed_cmd[@]}" "$SOURCES_DIR"/*.list || ran=0
    elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
      sudo "${sed_cmd[@]}" "$SOURCES_DIR"/*.list || ran=0
    else
      ran=0
    fi
    if [ "$ran" -eq 1 ]; then
      echo "==> dropped the ROS 1 gbpdistro source (unused, and the one that rate limits)"
    else
      echo "==> could not drop the ROS 1 gbpdistro source (needs root) — relying on retries"
    fi
  fi

  local attempt
  for attempt in $(seq 1 "$ATTEMPTS"); do
    if rosdep update --rosdistro "$DISTRO"; then
      echo "==> rosdep update ok (attempt ${attempt})"
      return 0
    fi
    if [ "$attempt" -lt "$ATTEMPTS" ]; then
      # Linear backoff. The limit resets on a clock, not on load, so waiting longer
      # each time costs little and helps more than hammering.
      local delay=$((attempt * 15))
      echo "==> rosdep update failed (attempt ${attempt}/${ATTEMPTS}) — retrying in ${delay}s"
      sleep "$delay"
    fi
  done

  echo "FAIL: rosdep update failed ${ATTEMPTS} times." >&2
  echo "      If this is a 429, GitHub is rate limiting an unauthenticated fetch;" >&2
  echo "      if it is anything else, rosdep itself is broken and the build should stop." >&2
  return 1
}

main "$@"
