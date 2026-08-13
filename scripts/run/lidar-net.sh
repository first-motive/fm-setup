#!/usr/bin/env bash
#
# lidar-net — give the Livox MID-360 its own network interface, via netplan.
#
#   ./run.sh lidar-net enx0a1b2c3d4e5f       # the USB 3 Ethernet adapter
#   ./run.sh lidar-net --remove
#
# The lidar sits at 192.168.1.131 and expects the host at 192.168.1.10. Putting
# that second 192.168.1.x on the LAN NIC blackholes the LAN's return path in a
# way only a reboot heals, so the lidar gets a dedicated interface — on the
# Jetson, a USB 3 Ethernet adapter.
#
# Netplan, not nmcli: the appliance runs Ubuntu Server, which ships
# systemd-networkd and no NetworkManager. This was a hand-typed nmcli command in
# a doc; a host mutation belongs in a committed script that can also undo it.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$_here/../.." && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$FM_ROOT/lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$FM_ROOT/scripts/manifest.sh"

PLAN=/etc/netplan/90-fm-lidar.yaml

usage() {
  cat <<EOF
lidar-net — dedicated interface for the Livox MID-360 (netplan)

Usage: ./run.sh lidar-net <interface>
       ./run.sh lidar-net --remove
       ./run.sh lidar-net --help

  <interface>   the dedicated NIC (a USB 3 Ethernet adapter), e.g. enx…
  --remove      delete the profile and re-apply netplan

Host lands at $FM_LIDAR_HOST_IP with a route to $FM_LIDAR_IP only — never a
default route, so LAN traffic cannot leak onto this link. List candidate
interfaces with: ip -brief link
EOF
}

write_plan() {
  local ifname="$1"

  if [ -f "$PLAN" ] && grep -q "  $ifname:" "$PLAN" 2>/dev/null; then
    fm_ok "$PLAN already targets $ifname"
    return 0
  fi

  fm_log "writing $PLAN for $ifname"
  # 0600: netplan warns on world-readable files, and this one is root's.
  sudo install -m 0600 -o root -g root /dev/null "$PLAN"
  sudo tee "$PLAN" >/dev/null <<EOF
# Managed by fm-setup (./run.sh lidar-net). Dedicated link to the Livox MID-360.
# No gateway on purpose: this interface must never carry a default route.
network:
  version: 2
  ethernets:
    $ifname:
      optional: true
      addresses:
        - $FM_LIDAR_HOST_IP/24
      routes:
        - to: $FM_LIDAR_IP/32
          scope: link
EOF
  sudo netplan apply
  fm_ok "$ifname holds $FM_LIDAR_HOST_IP; lidar expected at $FM_LIDAR_IP"
  fm_info "prove it with: ping -c2 $FM_LIDAR_IP"
}

remove_plan() {
  if [ ! -f "$PLAN" ]; then
    fm_skip "$PLAN not present"
    return 0
  fi
  sudo rm -f "$PLAN"
  sudo netplan apply
  fm_ok "$PLAN removed"
}

main() {
  local ifname=""

  case "${1:-}" in
    -h|--help) usage; return 0 ;;
    --remove)  fm_require_linux; remove_plan; return 0 ;;
    "") fm_err "an interface is required"; usage; return 1 ;;
    -*) fm_err "unknown option: $1"; usage; return 1 ;;
    *)  ifname="$1" ;;
  esac

  fm_require_linux
  fm_require_cmd netplan

  # The name lands inside a YAML document this script writes as root.
  case "$ifname" in
    *[!a-zA-Z0-9_.-]*)
      fm_err "invalid interface name: '$ifname'"
      return 1 ;;
  esac
  if ! ip link show "$ifname" >/dev/null 2>&1; then
    fm_err "no interface '$ifname' on this machine"
    fm_info "candidates: $(ip -brief link 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
    return 1
  fi

  write_plan "$ifname"
}

main "$@"
