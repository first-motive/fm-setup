#!/usr/bin/env bash
#
# seed-jetson.sh — the cloud-init seed a Jetson capture rig boots from.
#
#   scripts/internal/seed-jetson.sh --out <dir> --name fm-rec-01 \
#     --authorized-keys <file> --setup-url <url> --ros2-url <url>
#
# Writes user-data, meta-data, and network-config into <dir>. `./run.sh flash`
# then replaces the NoCloud seed baked into the image's ext4 rootfs with these
# three files, because a baked seed beats any file laid on the FAT partition.
#
# Called by flash, and standalone by scripts/dev/test-flash.sh, which is the
# reason it is a script rather than three functions inside flash: a seed that is
# only reachable through a 5 GB image write is a seed nobody checks.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$_here/../.." && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$FM_ROOT/lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$FM_ROOT/scripts/manifest.sh"
# shellcheck source=./seed-lib.sh disable=SC1091
. "$_here/seed-lib.sh"

ROLE=jetson

# Wifi is the jetson's alone — the workstation is a wired box — so it is
# declared here rather than in the shared library.
#
# The PSK is a secret, so it defaults from the environment for the same reason
# the token does: an argument to a process is readable from the process table.
# The flag stays, for a scripted caller and for the CI rehearsal.
SEED_WIFI_SSID=""
SEED_WIFI_PSK=""
if [ -n "${FM_FLASH_WIFI:-}" ]; then
  SEED_WIFI_SSID="${FM_FLASH_WIFI%%:*}"
  SEED_WIFI_PSK="${FM_FLASH_WIFI#*:}"
fi

usage() {
  cat <<EOF
seed-jetson.sh — the cloud-init seed a Jetson capture rig boots from

Usage: scripts/internal/seed-jetson.sh --out <dir> [options]

$(fm_seed_usage_common)
  --wifi <ssid:psk>        join this network on boot (Ethernet needs nothing)
EOF
}

# --- Seed files -------------------------------------------------------------

build_network_config() {
  cat <<EOF
# Seeded by fm-setup (./run.sh flash). Ethernet always; wifi when creds given.
version: 2
ethernets:
  all-eth:
    match: {name: "e*"}
    dhcp4: true
    optional: true
EOF
  if [ -n "$SEED_WIFI_SSID" ]; then
    cat <<EOF
wifis:
  all-wl:
    match: {name: "wl*"}
    dhcp4: true
    optional: true
    access-points:
      $(fm_seed_yaml_quote "$SEED_WIFI_SSID"):
        password: $(fm_seed_yaml_quote "$SEED_WIFI_PSK")
EOF
  fi
}

build_user_data() {
  cat <<EOF
#cloud-config
# Seeded by fm-setup (./run.sh flash). One appliance, no wizard.
hostname: $SEED_HOSTNAME
manage_etc_hosts: true
ssh_pwauth: false
package_update: true
# avahi-daemon earns its place: the image resolves hosts through "files dns"
# only, so without it $SEED_HOSTNAME.local answers nowhere and the appliance is
# reachable by IP alone — on a rig that is handed over screenless, that is the
# difference between working and lost. Installed before runcmd, so the
# provisioning chain is already followable over .local.
packages: [curl, git, avahi-daemon, libnss-mdns]
users:
  - name: $SEED_USER
    gecos: First Motive appliance
    groups: [adm, sudo, dialout, video, plugdev]
    shell: /bin/bash
    lock_passwd: true
    # Appliance owner on a single-purpose box; the install chain and the
    # auto-updater both need root without a console to type a password into.
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
$(fm_seed_authorized_keys_yaml "      ")
write_files:
  - path: $FM_MACHINE_FILE_LINUX
    permissions: "0644"
    content: |
$(fm_seed_card "$ROLE" "      ")
EOF
  if [ "$SEED_PROVISION" = 1 ]; then
    cat <<EOF
  - path: /usr/local/sbin/fm-first-boot.sh
    permissions: "0700"
    content: |
EOF
    fm_seed_first_boot "$ROLE" | sed 's/^/      /'
    cat <<EOF
runcmd:
  - [bash, /usr/local/sbin/fm-first-boot.sh]
EOF
  fi
}

main() {
  fm_seed_parse_args "$@"

  local i=0 pair
  while [ "$i" -lt "${#SEED_REST[@]}" ]; do
    case "${SEED_REST[$i]}" in
      --wifi)
        pair="${SEED_REST[$((i + 1))]:-}"
        case "$pair" in *:*) ;; *) fm_err "--wifi wants ssid:psk"; return 1 ;; esac
        SEED_WIFI_SSID="${pair%%:*}"; SEED_WIFI_PSK="${pair#*:}"; i=$((i + 2)) ;;
      -h|--help) usage; return 0 ;;
      *) fm_err "unknown option: ${SEED_REST[$i]}"; usage; return 1 ;;
    esac
  done

  fm_seed_require "$ROLE"

  build_user_data      >"$SEED_OUT/user-data"
  build_network_config >"$SEED_OUT/network-config"
  cat >"$SEED_OUT/meta-data" <<EOF
dsmode: local
instance_id: $SEED_HOSTNAME
EOF
}

main "$@"
