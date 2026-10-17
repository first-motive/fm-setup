#!/usr/bin/env bash
#
# comms-bridge — fm-comms' zenoh bridge on a cloud sim host.
#
# The sim agent's verbs reach the router on their own. A run's state — joint
# states, tf, cameras, the outcome — reaches the fleet only through the zenoh
# bridge, which on a workstation fm_ros2 installs from fm-comms. Nothing runs
# fm_ros2 on a cloud host, so this step installs the bridge the same way, with
# fm-comms' own installer (`install.sh --role bridge`):
#
#   - Root fetches fm-comms at FM_COMMS_COMMIT, the commit FM_COMMS_TAG names
#     (the tag fm_ros2 pins), into FM_COMMS_ROOT with a scrubbed git
#     environment, and refuses a checkout at any other commit.
#   - /etc/fm-comms.env is placed from that commit's example when absent, then
#     given this host's three values: FM_ROUTER_ENDPOINT from host.env,
#     FM_ROS_DISTRO (the sim image's Jazzy), and FM_SIM_IMAGE at
#     FM_SIM_IMAGE_DIGEST. Every other line is the example's, or whatever was
#     there before.
#   - fm-comms' installer pins and holds zenoh-bridge-ros2dds, renders the
#     profile the card's `workload: sim` selects — bridge-sim.json5, outbound
#     publishers only, on a loopback DDS graph — and enables
#     fm-zenoh-bridge.service. Nothing here names a profile, an interface, or
#     an allow-list: the bridge is exactly what fm-comms ships.
#
# install fails when the unit is not enabled afterwards. sim-cloud-ready checks
# it is still active at the end of the role.
#
# Test hooks, for scripts/dev/test-sim-cloud.sh only and refused without
# FM_SIM_TEST=1: FM_SIM_TEST_ROOT prefixes every path the step writes;
# FM_SIM_TEST_COMMS_SOURCE and FM_SIM_TEST_COMMS_COMMIT replace the GitHub URL
# and the pin, and both need a valid FM_SIM_TEST_ROOT.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$_here/../.." && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$FM_ROOT/lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$FM_ROOT/scripts/manifest.sh"
# shellcheck source=../internal/sim-lib.sh disable=SC1091
. "$FM_ROOT/scripts/internal/sim-lib.sh"
# shellcheck source=../internal/sim-cloud-lib.sh disable=SC1091
. "$FM_ROOT/scripts/internal/sim-cloud-lib.sh"

fm_require_linux

# Literal, because the drift audit reads this line with sed. It is FM_COMMS_BRIDGE_UNIT.
# shellcheck disable=SC2034
FM_UNITS=(fm-zenoh-bridge.service)

R="${FM_SIM_TEST_ROOT:-}"
if [ -n "$R" ]; then sim_test_root_ok "$R" || exit 1; fi
if { [ -n "${FM_SIM_TEST_COMMS_SOURCE:-}" ] || [ -n "${FM_SIM_TEST_COMMS_COMMIT:-}" ]; } && [ -z "$R" ]; then
  fm_err "FM_SIM_TEST_COMMS_SOURCE and FM_SIM_TEST_COMMS_COMMIT need FM_SIM_TEST_ROOT — refusing"
  exit 1
fi
SOURCE_URL="${FM_SIM_TEST_COMMS_SOURCE:-https://github.com/$FM_COMMS_REPO.git}"
COMMIT="${FM_SIM_TEST_COMMS_COMMIT:-$FM_COMMS_COMMIT}"
TREE="$R$FM_COMMS_ROOT"
COMMS_ENV=/etc/fm-comms.env

# git with nothing inherited, as 91-sim.sh runs it: root, against its own tree.
GIT_ENV=(env -i PATH=/usr/bin:/bin HOME=/nonexistent GIT_NO_REPLACE_OBJECTS=1
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0)
tree_git() { sudo "${GIT_ENV[@]}" git -c "safe.directory=$TREE" -C "$TREE" "$@"; }
tree_head() { "${GIT_ENV[@]}" git -c "safe.directory=$TREE" -C "$TREE" rev-parse --verify --quiet HEAD 2>/dev/null || true; }

image_ref() { printf '%s@%s\n' "${FM_SIM_IMAGE%:*}" "$FM_SIM_IMAGE_DIGEST"; }

# The env file's text once this host's three values are set.
comms_text() {
  local text=""
  [ -f "$R$COMMS_ENV" ] && text="$(cat "$R$COMMS_ENV")"
  text="$(sim_cloud_set_key "$text" FM_ROUTER_ENDPOINT "$FM_ROUTER_ENDPOINT")"
  text="$(sim_cloud_set_key "$text" FM_ROS_DISTRO "$FM_SIM_CLOUD_ROS_DISTRO")"
  sim_cloud_set_key "$text" FM_SIM_IMAGE "$(image_ref)"
}

unit_enabled() { systemctl is-enabled --quiet "$FM_COMMS_BRIDGE_UNIT" 2>/dev/null; }

do_check() {
  if [ "$(tree_head)" = "$COMMIT" ]; then
    fm_ok "$FM_COMMS_ROOT is fm-comms $FM_COMMS_TAG ($COMMIT)"
  else
    fm_warn "$FM_COMMS_ROOT is not fm-comms at $COMMIT"
  fi
  if sim_cloud_env_ok 2>/dev/null && [ -f "$R$COMMS_ENV" ] && [ "$(cat "$R$COMMS_ENV")" = "$(comms_text)" ]; then
    fm_ok "$COMMS_ENV names router $FM_ROUTER_ENDPOINT"
  else
    fm_warn "$COMMS_ENV missing or out of date"
  fi
  if unit_enabled; then fm_ok "$FM_COMMS_BRIDGE_UNIT enabled"; else fm_warn "$FM_COMMS_BRIDGE_UNIT not enabled"; fi
  if systemctl is-active --quiet "$FM_COMMS_BRIDGE_UNIT" 2>/dev/null; then
    fm_ok "$FM_COMMS_BRIDGE_UNIT active"
  else
    fm_warn "$FM_COMMS_BRIDGE_UNIT not active"
  fi
  return 0
}

# Root fetches the one commit and checks it out; any other HEAD is refused.
fetch_comms() {
  if [ "$(tree_head)" = "$COMMIT" ]; then
    fm_ok "$FM_COMMS_ROOT already at $COMMIT"
    return 0
  fi
  sudo install -d -o root -g root -m 0755 "$TREE" || { fm_err "creating $FM_COMMS_ROOT failed"; return 1; }
  [ -d "$TREE/.git" ] || tree_git init --quiet || { fm_err "creating $FM_COMMS_ROOT's repository failed"; return 1; }
  fm_log "fetching fm-comms $FM_COMMS_TAG ($COMMIT, as root)"
  tree_git fetch --quiet --depth 1 "$SOURCE_URL" "$COMMIT" \
    || { fm_err "fetching $COMMIT from $SOURCE_URL failed"; return 1; }
  tree_git checkout --quiet --force --detach "$COMMIT" || { fm_err "checking out $COMMIT failed"; return 1; }
  [ "$(tree_head)" = "$COMMIT" ] || { fm_err "$FM_COMMS_ROOT is at '$(tree_head)', not the pinned $COMMIT"; return 1; }
  fm_ok "$FM_COMMS_ROOT at $COMMIT"
}

# Place the env file from the pinned example, then set this host's values.
write_env() {
  local example="$TREE/systemd/fm-comms.env.example" stage rc=0
  if [ ! -f "$R$COMMS_ENV" ]; then
    [ -f "$example" ] || { fm_err "fm-comms $COMMIT has no systemd/fm-comms.env.example"; return 1; }
    sudo install -m 0644 "$example" "$R$COMMS_ENV" || { fm_err "placing $COMMS_ENV failed"; return 1; }
  fi
  if [ "$(cat "$R$COMMS_ENV")" = "$(comms_text)" ]; then
    fm_ok "$COMMS_ENV current"
    return 0
  fi
  stage="$(sudo mktemp "$R$COMMS_ENV.XXXXXX")" || { fm_err "staging $COMMS_ENV failed"; return 1; }
  if ! { comms_text | sudo tee "$stage" >/dev/null && sudo chmod 0644 "$stage" && sudo mv "$stage" "$R$COMMS_ENV"; }; then
    fm_err "writing $COMMS_ENV failed"
    rc=1
  fi
  sudo rm -f "$stage"
  [ "$rc" = 0 ] && fm_ok "$COMMS_ENV names router $FM_ROUTER_ENDPOINT, ROS $FM_SIM_CLOUD_ROS_DISTRO"
  return "$rc"
}

do_install() {
  sim_cloud_env_ok || return 1
  if [ "${1:-}" = "--dry-run" ]; then
    fm_info "would fetch $COMMIT ($FM_COMMS_TAG) from $SOURCE_URL into $FM_COMMS_ROOT (as root)"
    fm_info "would set   FM_ROUTER_ENDPOINT, FM_ROS_DISTRO=$FM_SIM_CLOUD_ROS_DISTRO, FM_SIM_IMAGE in $COMMS_ENV"
    fm_info "would run   $FM_COMMS_ROOT/install.sh install --role bridge (renders bridge-sim, enables $FM_COMMS_BRIDGE_UNIT)"
    return 0
  fi
  fm_has_cmd systemctl || { fm_err "no systemctl — the bridge is a systemd service"; return 1; }

  fetch_comms || return 1
  write_env || return 1

  fm_log "installing fm-comms' bridge (workload sim)"
  FM_YES=1 FM_NO_MODIFY_PATH=1 FM_ROUTER_ENDPOINT="$FM_ROUTER_ENDPOINT" \
    bash "$TREE/install.sh" install --role bridge \
    || { fm_err "fm-comms' bridge installer failed"; return 1; }
  # fm-comms installs and holds the package from Eclipse's repo itself, so there
  # is no fm_apt_install call to diff. The package it lands is named here.
  fm_ledger_record comms-bridge zenoh-bridge-ros2dds

  unit_enabled || { fm_err "$FM_COMMS_BRIDGE_UNIT is not enabled after fm-comms' installer"; return 1; }
  fm_ok "$FM_COMMS_BRIDGE_UNIT enabled — bridge-sim to $FM_ROUTER_ENDPOINT"
}

do_uninstall() {
  if [ -f "$TREE/install.sh" ]; then
    FM_YES=1 bash "$TREE/install.sh" uninstall --role bridge || { fm_err "fm-comms' bridge uninstall failed"; return 1; }
  else
    fm_skip "fm-comms not installed"
  fi
  if [ -d "$TREE" ]; then
    sudo rm -rf "$TREE" || { fm_err "removing $FM_COMMS_ROOT failed"; return 1; }
    fm_ok "$FM_COMMS_ROOT removed"
  fi
  fm_warn "$COMMS_ENV left in place — the sim agent's unit reads it too"
}

fm_dispatch "$@"
