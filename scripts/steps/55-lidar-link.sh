#!/usr/bin/env bash
#
# lidar-link — give the recorder's Ethernet port the address its Livox LiDAR talks to.
#
# The Livox MID-360S is plugged straight into the Jetson's one Ethernet port and
# sends to a fixed host address. Nothing configured that address, so on fm-rec-01
# the driver logged "bind failed" on every boot and the LiDAR never produced a
# point until it was added by hand (2026-09-30).
#
# Both addresses come from fm-data's livox_mid360s.json, the file the driver
# itself reads, so there is one copy of them. They sit inside the office /24 that
# Wi-Fi also carries, so the port gets the host address as a /32 plus a host
# route to the LiDAR alone. Wi-Fi keeps the rest of the subnet and the default
# route.
#
# The mechanism is a systemd-networkd .network file, because networkd is what
# runs this port: NetworkManager leaves it unmanaged, and cloud-init's netplan
# renders /run/systemd/network/10-netplan-all-eth.network for it. networkd uses
# the first matching file by name, so 05-… replaces that file for e* ports. It
# carries netplan's settings over unchanged, DHCP included, and adds the address
# and route. A netplan drop-in would have to merge into cloud-init's `all-eth`
# id, and applying it means `netplan apply` on a host whose Wi-Fi is the only
# way in.
#
# Acts only on a recorder that runs the LiDAR: FM_RECORDER_LIDAR=on, or auto with
# the driver node built — the same test recorder-boot.sh makes.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$_here/../.." && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$FM_ROOT/lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$FM_ROOT/scripts/manifest.sh"

fm_require_linux

NETWORK_FILE=/etc/systemd/network/05-fm-lidar.network
RECORDER_ENV=/etc/fm-recorder.env
# fm-recorder.service runs as fm, and the driver overlay lives in that home.
RECORDER_USER=fm
LIVOX_JSON="$(fm_machine_workspace)/fm_ros2/install/fm_data_sensors/share/fm_data_sensors/config/livox_mid360s.json"

# lidar_wanted — 0 when this host's recorder runs the LiDAR, else explains why not.
lidar_wanted() {
  local workload mode home
  workload="$(fm_machine_workload)"
  [ "$workload" = recorder ] || { echo "workload is '${workload:-none}', not recorder"; return 1; }
  mode="auto"
  [ -f "$RECORDER_ENV" ] && mode="$(sed -n 's/^FM_RECORDER_LIDAR=//p' "$RECORDER_ENV" | tail -1)"
  case "${mode:-auto}" in
    on) ;;
    auto)
      home="$(getent passwd "$RECORDER_USER" | cut -d: -f6)"
      [ -x "$home/ws_livox/install/livox_ros_driver2/lib/livox_ros_driver2/livox_ros_driver2_node" ] \
        || { echo "FM_RECORDER_LIDAR=auto and the Livox driver is not built"; return 1; } ;;
    *) echo "FM_RECORDER_LIDAR=$mode"; return 1 ;;
  esac
  [ -f "$LIVOX_JSON" ] || { echo "$LIVOX_JSON missing — build fm_ros2 first"; return 1; }
}

# The file's values go into a root-owned network config; accept dotted quads only.
json_ip() {
  local ip
  ip="$(jq -er "$1" "$LIVOX_JSON")" || return 1
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { fm_err "not an IPv4 address in $LIVOX_JSON: $ip"; return 1; }
  printf '%s\n' "$ip"
}

render() {
  local host_ip lidar_ip
  host_ip="$(json_ip '.Mid360s.host_net_info[0].host_ip')" || return 1
  lidar_ip="$(json_ip '.lidar_configs[0].ip')" || return 1
  cat <<EOF
# Written by fm-setup (55-lidar-link.sh) from livox_mid360s.json.
# Replaces cloud-init's 10-netplan-all-eth.network for e* ports: same settings,
# plus the Livox host address and a route to the LiDAR alone.
[Match]
Name=e*

[Link]
RequiredForOnline=no

[Network]
DHCP=ipv4
LinkLocalAddressing=ipv6
Address=$host_ip/32

[DHCP]
RouteMetric=100
UseMTU=true

[Route]
Destination=$lidar_ip/32
PreferredSource=$host_ip
Scope=link
EOF
}

# Apply to the e* ports only. Wi-Fi is NetworkManager's and is never touched.
reconfigure() {
  local dev
  sudo -n networkctl reload
  for dev in /sys/class/net/e*; do
    [ -e "$dev" ] && sudo -n networkctl reconfigure "${dev##*/}"
  done
  return 0
}

do_check() {
  local why want lidar_ip
  if ! why="$(lidar_wanted)"; then
    fm_skip "$why"
    return 0
  fi
  if ! want="$(render)"; then
    fm_warn "cannot read the LiDAR addresses from $LIVOX_JSON"
    return 0
  fi
  if [ "$(cat "$NETWORK_FILE" 2>/dev/null)" = "$want" ]; then
    fm_ok "$NETWORK_FILE matches livox_mid360s.json"
  else
    fm_warn "$NETWORK_FILE missing or differs from livox_mid360s.json"
  fi
  lidar_ip="$(json_ip '.lidar_configs[0].ip')"
  fm_info "route to LiDAR: $(ip -o route get "$lidar_ip" 2>/dev/null || echo none)"
  return 0
}

do_install() {
  local why want
  if ! why="$(lidar_wanted)"; then
    fm_skip "$why"
    return 0
  fi
  want="$(render)"
  if [ "$(cat "$NETWORK_FILE" 2>/dev/null)" = "$want" ]; then
    fm_skip "$NETWORK_FILE already current"
    return 0
  fi
  printf '%s\n' "$want" | sudo -n tee "$NETWORK_FILE" >/dev/null
  sudo -n chmod 644 "$NETWORK_FILE"
  reconfigure
  fm_ok "wrote $NETWORK_FILE and reconfigured the Ethernet port"
}

do_uninstall() {
  if [ ! -f "$NETWORK_FILE" ]; then
    fm_skip "$NETWORK_FILE not present"
    return 0
  fi
  sudo -n rm -f "$NETWORK_FILE"
  reconfigure
  fm_ok "removed $NETWORK_FILE; the Ethernet port is back on cloud-init's netplan config"
}

fm_dispatch "$@"
