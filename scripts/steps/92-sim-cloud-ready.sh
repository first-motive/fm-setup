#!/usr/bin/env bash
#
# sim-cloud-ready — fail the role unless this host would serve sim runs.
#
# Several steps before this one stop at a gate and exit 0, which suits a host a
# person comes back to. A cloud sim host has nobody to come back: its bootstrap
# terminates the instance when the role fails, and a host that finished without
# serving would bill until its idle check ends it. So the role ends by checking
# what fm-sim's stack relies on, and fails when any of it is missing:
#
#   - docker is active, and the NVIDIA driver answers (the image ships it);
#   - fm-sim-agent.service is enabled, and still active a few seconds after
#     the sim step started it, so a unit that starts and crashes is caught;
#   - the agent's account, FM_SIM_USER, is in the docker group;
#   - fm-zenoh-bridge.service is enabled and active, so a run's state reaches
#     the fleet;
#   - the node is joined to the tailnet as FM_TS_TAG.
#
# check reports the same list and changes nothing. uninstall has nothing to
# reverse.
#
# Test hook, for scripts/dev/test-sim-cloud.sh only: FM_SIM_TEST=1 with
# FM_SIM_TEST_SETTLE sets the wait in seconds.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$_here/../.." && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$FM_ROOT/lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$FM_ROOT/scripts/manifest.sh"
# shellcheck source=../internal/sim-cloud-lib.sh disable=SC1091
. "$FM_ROOT/scripts/internal/sim-cloud-lib.sh"

fm_require_linux

# How long the agent must stay active before it counts as running.
SETTLE=5
if [ -n "${FM_SIM_TEST_SETTLE:-}" ]; then
  [ "${FM_SIM_TEST:-0}" = 1 ] || { fm_err "FM_SIM_TEST_SETTLE is a test hook and needs FM_SIM_TEST=1 — refusing"; exit 1; }
  SETTLE="$FM_SIM_TEST_SETTLE"
fi

# report — one line per requirement; 0 when every one holds.
report() {
  local bad=0
  if systemctl is-active --quiet docker 2>/dev/null; then fm_ok "docker active"; else fm_err "docker is not active"; bad=1; fi
  if nvidia-smi -L >/dev/null 2>&1; then fm_ok "NVIDIA driver answers"; else fm_err "nvidia-smi fails — the image must ship the driver"; bad=1; fi
  if systemctl is-enabled --quiet "$FM_SIM_UNIT" 2>/dev/null; then
    fm_ok "$FM_SIM_UNIT enabled"
  else
    fm_err "$FM_SIM_UNIT is not enabled — see the sim step's output above"; bad=1
  fi
  if systemctl is-active --quiet "$FM_SIM_UNIT" 2>/dev/null; then
    fm_ok "$FM_SIM_UNIT active"
  else
    fm_err "$FM_SIM_UNIT is not active — journalctl -u $FM_SIM_UNIT says why"; bad=1
  fi
  if systemctl is-enabled --quiet "$FM_COMMS_BRIDGE_UNIT" 2>/dev/null \
      && systemctl is-active --quiet "$FM_COMMS_BRIDGE_UNIT" 2>/dev/null; then
    fm_ok "$FM_COMMS_BRIDGE_UNIT enabled and active"
  else
    fm_err "$FM_COMMS_BRIDGE_UNIT is not enabled and active — journalctl -u $FM_COMMS_BRIDGE_UNIT says why"; bad=1
  fi
  if id -nG "$FM_SIM_USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
    fm_ok "$FM_SIM_USER in the docker group"
  else
    fm_err "$FM_SIM_USER is not in the docker group"; bad=1
  fi
  if sim_cloud_has_tag "${FM_TS_TAG:-}"; then
    fm_ok "joined to the tailnet as ${FM_TS_TAG:-}"
  else
    fm_err "not joined to the tailnet as ${FM_TS_TAG:-FM_TS_TAG}"; bad=1
  fi
  return "$bad"
}

do_check() {
  report || true
  return 0
}

do_install() {
  if [ "${1:-}" = "--dry-run" ]; then
    fm_info "would check docker, the driver, $FM_SIM_UNIT, $FM_COMMS_BRIDGE_UNIT, the docker grant, and the tailnet join"
    return 0
  fi
  sleep "$SETTLE"
  report || { fm_err "this host would not serve sim runs — failing the sim-cloud role"; return 1; }
  fm_ok "serving fm/sim/$(fm_machine_namespace)/*"
}

do_uninstall() {
  fm_skip "sim-cloud-ready changes nothing"
}

fm_dispatch "$@"
