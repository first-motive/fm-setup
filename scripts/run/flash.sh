#!/usr/bin/env bash
#
# flash — build a provisioned Jetson SD card, from the machine with the SD slot.
#
#   ./run.sh flash --device /dev/disk4                       # macOS
#   ./run.sh flash --device /dev/sdb --wifi "rig-lan:secret" # Linux
#
# Writes Canonical's Ubuntu Server image for Jetson Orin (pinned in
# scripts/manifest.sh) with the cloud-init seed replaced before the write, so
# the first boot needs no monitor, keyboard, or wizard: hostname, appliance
# user, SSH keys, and optional wifi are decided before power-on, and a
# first-boot script chains fm-setup's jetson role and (with --gh-token)
# fm_ros2's recorder install. The card comes out of this script ready to
# record.
#
# Why the seed is replaced in the image, not dropped on the card: this image
# bakes its NoCloud seed into the ext4 rootfs (/var/lib/cloud/seed/nocloud —
# the ubuntu/ubuntu first-login wizard), and a baked seed beats any file laid
# on the FAT partition. So the flow is: clone the cached image (copy-on-write
# where the filesystem offers it), loop-mount the rootfs at the pinned offset,
# swap the seed, then flash the clone. On macOS the ext4 mount happens inside
# a privileged container (OrbStack/Docker); on Linux it is a plain loop mount.
#
# Engine: balena CLI when present (validates after write), otherwise dd. The
# target must be a whole, external disk — internal disks are refused outright.
#
# Firmware prerequisite, documented not automated: the board's QSPI must carry
# NVIDIA's r36.x UEFI firmware. Any Orin that has booted JetPack 6 qualifies.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$_here/../.." && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$FM_ROOT/lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$FM_ROOT/scripts/manifest.sh"

# The exact install.sh a flashed rig fetches on first boot: this repo's release
# tag, resolved from the one place it is written down, joined to the raw base in
# the manifest. Resolved here at flash time rather than left as a ref the rig
# looks up later, so a card carries the release it was flashed from even if the
# tag is moved afterwards.
FM_SETUP_INSTALL_URL="$FM_SETUP_RAW_BASE/$(fm_release_tag "$FM_ROOT")/install.sh"

# The workspace layer's ref, resolved the same way and at the same moment. This
# repo's tag is read from its own install.sh; fm_ros2's has to be asked of the
# remote, because there is no fm_ros2 checkout here to read it from. Newest v*
# tag wins, git does the version sort.
#
# No tag is a real answer, not an error: a repo that has never been released has
# nothing to pin to, and refusing to flash would be worse than saying so. That
# path falls back to main and says which it took, because the difference is the
# whole point of this line.
fm_ros2_ref() {
  local tag
  tag="$(git ls-remote --refs --tags --sort=-v:refname "$FM_ROS2_REPO_URL" 'v*' 2>/dev/null \
    | awk -F/ 'NR==1{print $NF}')"
  if [ -n "$tag" ]; then
    printf '%s\n' "$tag"
  else
    fm_warn "fm_ros2 has no v* tag — the workspace layer will install from main"
    printf 'main\n'
  fi
}

FM_ROS2_INSTALL_URL="$FM_ROS2_RAW_BASE/$(fm_ros2_ref)/install.sh"

CACHE_DIR="${FM_FLASH_CACHE:-$HOME/.cache/fm-setup}"
IMAGE_XZ="$CACHE_DIR/$(basename "$FM_JETSON_IMAGE_URL")"
IMAGE_RAW="${IMAGE_XZ%.xz}"
WORK_IMG=""
SEED_DIR=""

DEVICE=""
# The card decides the hostname, not the other way round: a rig's name, its
# mDNS name, and the stem of its ROS namespace are one fact, seeded here so the
# appliance boots already knowing which recorder it is. 01 is a default that the
# second rig of a role must override — two cards claiming fm-rec-01 collide on
# the LAN exactly as the old singular fm-jetson did.
MACHINE_NAME="fm-$(fm_machine_abbrev jetson)-01"
MACHINE_FLEET="$FM_MACHINE_FLEET_DEFAULT"
MACHINE_TRANSPORT="${FM_MACHINE_TRANSPORTS[0]}"
# A flashed card is a capture rig, which is what makes recorder the right
# default here and no default at all in `machine init` — that verb runs on
# workstations and laptops too, where there is no bridge to select.
MACHINE_WORKLOAD=recorder
# One visible parent directory for every checkout, resolved once --user is
# known. Consumers read this out of the card rather than assuming a path.
MACHINE_WORKSPACE=""
NEW_HOSTNAME="$MACHINE_NAME"
NEW_USER="$FM_JETSON_USER"
WIFI_SSID=""
WIFI_PSK=""
# Secrets default from the environment, which keeps them out of shell history
# and out of the process table. A flag still overrides, for a scripted caller.
TS_AUTHKEY="${FM_TS_AUTHKEY:-}"
GH_TOKEN="${FM_GH_TOKEN:-}"
SSH_KEY_FILE=""
SSH_KEYS=""
PROVISION=1
DRY_RUN=0
ASSUME_YES=0

usage() {
  cat <<EOF
flash — build a provisioned Jetson SD card

Usage: ./run.sh flash --device <disk> [options]

  --device <disk>          target disk, whole device (macOS /dev/diskN,
                           Linux /dev/sdX). Internal disks are refused.
  --name <fm-rec-nn>       machine name, which is also the hostname, the mDNS
                           name, and the stem of the ROS namespace
                           (default: $MACHINE_NAME — override on the second rig)
  --fleet <name>           population this rig joins (default: $MACHINE_FLEET)
  --transport <profile>    middleware profile (default: $MACHINE_TRANSPORT)
  --workload <kind>        what the rig does (default: $MACHINE_WORKLOAD)
  --user <name>            appliance user (default: $FM_JETSON_USER)
  --ssh-key <file>         public key to authorize (default: every ~/.ssh/*.pub)
  --wifi <ssid:psk>        join this network on boot (Ethernet needs nothing)
  --tailscale-authkey <k>  join the tailnet on first boot (use an ephemeral key).
                           Prefer FM_TS_AUTHKEY, for the reason below.
  --gh-token <token>       read-only fine-grained PAT for the private overlays;
                           with it, the recorder service installs unattended.
                           Prefer FM_GH_TOKEN (below) — an argument is visible
                           in the process table and in shell history.
  --no-provision           identity only — skip the first-boot install chain
  --dry-run                print the plan, touch nothing
  -y, --yes                skip the erase confirmation

macOS needs a container runtime (OrbStack or Docker) for the seed swap — the
rootfs is ext4. Linux needs only sudo.

Read a secret from the environment instead of the command line, so it reaches
neither shell history nor the process table:

  read -rs FM_GH_TOKEN && export FM_GH_TOKEN
  read -rs FM_TS_AUTHKEY && export FM_TS_AUTHKEY
  ./run.sh flash --device <disk> -y

Every secret passed here lands in the card's seed in plain text until first
boot consumes it. Hand the card straight to the Jetson, and prefer
ephemeral/least-scope credentials.

First boot takes 15-30 min on the provisioning chain. Watch it:
  ssh $FM_JETSON_USER@$MACHINE_NAME.local tail -f /var/log/fm-first-boot.log
EOF
}

# --- Small helpers ----------------------------------------------------------

# Quote a value for YAML: double-quoted, with backslash, quote, and newline
# escaping — a newline smuggled into an ssid/psk must not become YAML structure.
yaml_quote() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  printf '"%s"' "$s"
}

require_sane_name() {
  # LC_ALL=C: a glob range follows the locale's collation, and under a UTF-8
  # locale a-z also matches uppercase — which would let an uppercase hostname
  # through onto a card that is baked into an SD card before anyone sees it.
  local LC_ALL=C
  local what="$1" value="$2"
  case "$value" in
    *[!a-z0-9-]*|""|-*)
      fm_err "invalid $what: '$value' (lowercase letters, digits, hyphens)"
      return 1 ;;
  esac
}

cleanup() {
  # The clone and the staged seed both carry secrets — never leave them behind.
  if [ -n "$WORK_IMG" ]; then rm -f "$WORK_IMG"; fi
  if [ -n "$SEED_DIR" ]; then rm -rf "$SEED_DIR"; fi
}
# INT/TERM/HUP as well as EXIT: a closed terminal during the long write or the
# equally long read-back would otherwise strand a 5 GB working image that
# carries the baked token in plain text.
trap cleanup EXIT INT TERM HUP

# --- Image ------------------------------------------------------------------

fetch_image() {
  mkdir -p "$CACHE_DIR"
  if [ ! -f "$IMAGE_XZ" ] || ! fm_verify_checksum "$IMAGE_XZ" "$FM_JETSON_IMAGE_SHA256" 2>/dev/null; then
    fm_log "downloading $(basename "$FM_JETSON_IMAGE_URL")"
    curl -fSL --proto '=https' -C - -o "$IMAGE_XZ" "$FM_JETSON_IMAGE_URL"
    fm_verify_checksum "$IMAGE_XZ" "$FM_JETSON_IMAGE_SHA256"
    rm -f "$IMAGE_RAW" # a fresh download invalidates the cached decompression
  fi
  fm_ok "image verified against the pinned sha256"
  if [ ! -f "$IMAGE_RAW" ]; then
    fm_log "decompressing (cached for the next flash)"
    fm_require_cmd xz
    xz -dk "$IMAGE_XZ"
  fi
}

# Clone the cached image for this card. On APFS the clone is copy-on-write and
# instant; elsewhere it is a plain copy.
clone_image() {
  WORK_IMG="$CACHE_DIR/.flash-$$.img"
  fm_log "staging a working copy of the image"
  cp -c "$IMAGE_RAW" "$WORK_IMG" 2>/dev/null || cp "$IMAGE_RAW" "$WORK_IMG"
}

# --- Target disk ------------------------------------------------------------

# Refuse anything that is not a whole, external disk. A typo here erases a
# drive, so every check fails closed.
validate_device_macos() {
  local info
  info="$(diskutil info "$DEVICE" 2>/dev/null)" || {
    fm_err "no such disk: $DEVICE"; fm_info "list disks with: diskutil list external"; return 1
  }
  printf '%s\n' "$info" | grep -q '^ *Whole: *Yes' || {
    fm_err "$DEVICE is a partition — pass the whole disk (e.g. /dev/disk4)"; return 1
  }
  # Removable or external, never both required: a Mac's built-in SD reader sits
  # on an internal bus and still holds a card anyone may write, while an
  # external enclosure may report its disk as fixed. Only a disk that is
  # internal *and* fixed is the machine's own, and that is what this refuses.
  printf '%s\n' "$info" | grep -Eq '^ *Removable Media: *Removable|^ *Device Location: *External' || {
    fm_err "$DEVICE is a fixed internal disk — refusing"
    fm_info "list candidates with: diskutil list external physical"
    fm_info "a card in the built-in reader appears under: diskutil list"
    return 1
  }
  fm_info "target: $(printf '%s\n' "$info" | grep -E '^ *Device / Media Name:|^ *Disk Size:' | sed 's/^ *//' | tr '\n' ' ')"
}

validate_device_linux() {
  [ -b "$DEVICE" ] || { fm_err "no such block device: $DEVICE"; return 1; }
  local type rm
  type="$(lsblk -ndo TYPE "$DEVICE")" || return 1
  rm="$(lsblk -ndo RM "$DEVICE")" || return 1
  [ "$type" = "disk" ] || { fm_err "$DEVICE is not a whole disk"; return 1; }
  [ "$rm" = "1" ] || { fm_err "$DEVICE is not removable — refusing"; return 1; }
  fm_info "target: $(lsblk -ndo NAME,SIZE,MODEL "$DEVICE")"
}

confirm_erase() {
  fm_warn "everything on $DEVICE will be erased"
  if [ "$ASSUME_YES" = 1 ]; then
    return 0
  fi
  fm_confirm "erase $DEVICE and write the Jetson image?" || {
    fm_err "aborted"; return 1
  }
}

# --- Seed content -----------------------------------------------------------

collect_ssh_keys() {
  local keys=""
  if [ -n "$SSH_KEY_FILE" ]; then
    [ -f "$SSH_KEY_FILE" ] || { fm_err "no such key file: $SSH_KEY_FILE"; return 1; }
    keys="$(cat "$SSH_KEY_FILE")"
  else
    local f
    for f in "$HOME"/.ssh/*.pub; do
      [ -f "$f" ] || continue
      keys="${keys}$(cat "$f")"$'\n'
    done
  fi
  [ -n "$keys" ] || {
    fm_err "no SSH public key found (~/.ssh/*.pub) — pass --ssh-key"
    fm_info "the card locks password login, so a key is the only door in"
    return 1
  }
  printf '%s' "$keys"
}

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
  if [ -n "$WIFI_SSID" ]; then
    cat <<EOF
wifis:
  all-wl:
    match: {name: "wl*"}
    dhcp4: true
    optional: true
    access-points:
      $(yaml_quote "$WIFI_SSID"):
        password: $(yaml_quote "$WIFI_PSK")
EOF
  fi
}

# The first-boot script cloud-init writes to the appliance and runs once.
#
# A failed layer stops the chain and leaves a marker (FM_FIRST_BOOT_FAILED,
# read by `machine doctor`) naming the step. It never prints "done" after a
# failure: an unattended rig that fails and reports done is the omission class
# this repo exists to remove (#28). SSH is up before this script runs, so
# stopping here still leaves a reachable rig.
build_first_boot_script() {
  cat <<EOF
#!/usr/bin/env bash
set -uo pipefail
exec >>/var/log/fm-first-boot.log 2>&1
echo "== fm first boot: \$(date) =="
export NONINTERACTIVE=1
rm -f "$FM_FIRST_BOOT_FAILED"
fail() {
  mkdir -p "\$(dirname "$FM_FIRST_BOOT_FAILED")"
  printf '%s\\n' "\$1" >"$FM_FIRST_BOOT_FAILED"
  echo "== fm first boot FAILED at: \$1 (\$(date)) =="
  exit 1
}
EOF
  if [ -n "$GH_TOKEN" ]; then
    cat <<EOF
install -o "$NEW_USER" -g "$NEW_USER" -m 0600 /dev/null "/home/$NEW_USER/.git-credentials"
printf 'https://x-access-token:%s@github.com\n' '$GH_TOKEN' >"/home/$NEW_USER/.git-credentials"
sudo -u "$NEW_USER" -H git config --global credential.helper store
EOF
  fi
  cat <<EOF
echo "-- machine layer: fm-setup --jetson"
machine_rc=0
sudo -u "$NEW_USER" -H bash -c 'curl -fsSL --proto "=https" $FM_SETUP_INSTALL_URL | bash -s -- --jetson -y' || machine_rc=\$?
EOF
  # The join runs before the machine layer's failure is acted on: a rig that
  # failed mid-provision is worth far more on the tailnet than off it, and the
  # tailscale step sits early enough in the role that a later failure leaves
  # the binary in place (#28).
  if [ -n "$TS_AUTHKEY" ]; then
    cat <<EOF
echo "-- tailscale join"
if command -v tailscale >/dev/null; then
  tailscale up --ssh --authkey '$TS_AUTHKEY' || echo "tailscale join failed; run 'sudo tailscale up --ssh' by hand"
else
  echo "tailscale not installed — join skipped"
fi
EOF
  fi
  cat <<EOF
[ "\$machine_rc" -eq 0 ] || fail "machine layer (fm-setup --jetson, exit \$machine_rc)"
EOF
  if [ -n "$GH_TOKEN" ]; then
    cat <<EOF
echo "-- workspace layer: fm_ros2 --recorder --service"
sudo -u "$NEW_USER" -H bash -c 'mkdir -p $MACHINE_WORKSPACE && cd $MACHINE_WORKSPACE && curl -fsSL --proto "=https" $FM_ROS2_INSTALL_URL | bash -s -- --recorder --service' \
  || fail "workspace layer (fm_ros2 --recorder --service)"
EOF
  else
    cat <<EOF
cat >"/home/$NEW_USER/NEXT-STEP.md" <<'NOTE'
Machine layer is provisioned. The recorder needs first-motive org access:
  gh auth login    # or place an SSH key
  mkdir -p $MACHINE_WORKSPACE && cd $MACHINE_WORKSPACE
  curl -fsSL --proto "=https" $FM_ROS2_INSTALL_URL | bash -s -- --recorder --service
NOTE
chown "$NEW_USER:$NEW_USER" "/home/$NEW_USER/NEXT-STEP.md"
echo "-- no --gh-token: recorder install deferred (see ~/NEXT-STEP.md)"
EOF
  fi
  cat <<EOF
echo "== fm first boot done: \$(date) =="
EOF
}

build_user_data() {
  cat <<EOF
#cloud-config
# Seeded by fm-setup (./run.sh flash). One appliance, no wizard.
hostname: $NEW_HOSTNAME
manage_etc_hosts: true
ssh_pwauth: false
package_update: true
# avahi-daemon earns its place: the image resolves hosts through "files dns"
# only, so without it $NEW_HOSTNAME.local answers nowhere and the appliance is
# reachable by IP alone — on a rig that is handed over screenless, that is the
# difference between working and lost. Installed before runcmd, so the
# provisioning chain is already followable over .local.
packages: [curl, git, avahi-daemon, libnss-mdns]
users:
  - name: $NEW_USER
    gecos: First Motive appliance
    groups: [adm, sudo, dialout, video, plugdev]
    shell: /bin/bash
    lock_passwd: true
    # Appliance owner on a single-purpose box; the install chain and the
    # auto-updater both need root without a console to type a password into.
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
EOF
  local line
  while IFS= read -r line; do
    [ -n "$line" ] && printf '      - %s\n' "$line"
  done <<<"$SSH_KEYS"
  # The identity card is seeded whether or not the install chain runs. It is
  # what the machine *is*, not part of provisioning it: a card-less rig cannot
  # derive a namespace, does not know its own workspace, and cannot be told
  # apart from the next rig off the same command.
  cat <<EOF
write_files:
  - path: $FM_MACHINE_FILE_LINUX
    permissions: "0644"
    content: |
EOF
  # The card comes from lib.sh's one emitter, indented into the YAML block the
  # same way the first-boot script below is. It used to be written inline here,
  # which is how a backslash meant for a heredoc ended up inside the JSON and
  # shipped a card no reader could parse.
  fm_machine_card_literal \
    "$MACHINE_NAME" jetson "$MACHINE_FLEET" "$MACHINE_TRANSPORT" \
    "$MACHINE_WORKLOAD" "$MACHINE_WORKSPACE" | sed 's/^/      /'
  if [ "$PROVISION" = 1 ]; then
    cat <<EOF
  - path: /usr/local/sbin/fm-first-boot.sh
    permissions: "0700"
    content: |
EOF
    build_first_boot_script | sed 's/^/      /'
    cat <<EOF
runcmd:
  - [bash, /usr/local/sbin/fm-first-boot.sh]
EOF
  fi
}

# Stage the three seed files, secrets included, under a 0700 dir the EXIT trap
# removes.
stage_seed() {
  SEED_DIR="$(mktemp -d "$CACHE_DIR/.seed.XXXXXX")"
  chmod 700 "$SEED_DIR"
  build_user_data >"$SEED_DIR/user-data"
  build_network_config >"$SEED_DIR/network-config"
  cat >"$SEED_DIR/meta-data" <<EOF
dsmode: local
instance_id: $NEW_HOSTNAME
EOF
}

# --- Seed injection ---------------------------------------------------------

# Replace the baked NoCloud seed inside the working image's ext4 rootfs.
inject_seed_linux() {
  local mnt
  mnt="$(mktemp -d)"
  sudo mount -o loop,offset=$((FM_JETSON_ROOTFS_OFFSET * 512)) "$WORK_IMG" "$mnt"
  sudo install -m 0644 "$SEED_DIR/user-data" "$SEED_DIR/meta-data" "$SEED_DIR/network-config" \
    "$mnt/var/lib/cloud/seed/nocloud/"
  sudo umount "$mnt"
  rmdir "$mnt"
}

inject_seed_macos() {
  fm_has_docker || {
    fm_err "the seed swap needs a container runtime on macOS (the rootfs is ext4)"
    fm_info "install OrbStack (brew install --cask orbstack) and retry"
    return 1
  }
  # One bind mount covers both: the working image and the staged seed live in
  # CACHE_DIR, and a directory bind is the shape every runtime supports.
  docker run --rm --privileged -v "$CACHE_DIR:/work" ubuntu:24.04 bash -euc "
    mkdir -p /mnt/root
    mount -o loop,offset=\$(( $FM_JETSON_ROOTFS_OFFSET * 512 )) '/work/$(basename "$WORK_IMG")' /mnt/root
    install -m 0644 '/work/$(basename "$SEED_DIR")/user-data' \
      '/work/$(basename "$SEED_DIR")/meta-data' \
      '/work/$(basename "$SEED_DIR")/network-config' \
      /mnt/root/var/lib/cloud/seed/nocloud/
    umount /mnt/root
  "
}

inject_seed() {
  fm_log "replacing the image's cloud-init seed"
  case "$(fm_detect_os)" in
    macos) inject_seed_macos ;;
    linux) inject_seed_linux ;;
  esac
  fm_ok "seed carries $NEW_USER@$NEW_HOSTNAME"
}

# --- Flash engines ----------------------------------------------------------

flash_balena() {
  local balena_bin
  balena_bin="$(command -v balena)"
  fm_log "flashing with balena ($balena_bin)"
  sudo "$balena_bin" local flash "$WORK_IMG" --drive "$DEVICE" --yes
}

# Echo the raw/character device for DEVICE — far faster than the buffered node
# on macOS, and the same path on Linux.
raw_device() {
  if [ "$(fm_detect_os)" = "macos" ]; then
    printf '/dev/r%s\n' "${DEVICE#/dev/}"
  else
    printf '%s\n' "$DEVICE"
  fi
}

flash_dd() {
  local raw rc=0
  raw="$(raw_device)"
  fm_log "flashing with dd"
  # dd's status is captured rather than left to errexit: this function is called
  # from an `if`, which disables errexit for its whole body, and a trailing sync
  # would otherwise mask a failed write behind its own success.
  if [ "$(fm_detect_os)" = "macos" ]; then
    diskutil unmountDisk force "$DEVICE" >/dev/null
    sudo dd if="$WORK_IMG" of="$raw" bs=16m status=progress || rc=$?
  else
    sudo umount "${DEVICE}"?* 2>/dev/null || true
    sudo dd if="$WORK_IMG" of="$raw" bs=16M oflag=direct status=progress || rc=$?
  fi
  sync
  return "$rc"
}

# Read the card back and compare it to what was written. dd reports a short
# write on stderr and nothing else, so without this a card that dropped off the
# bus mid-write still carries a valid-looking partition table over a filesystem
# that is half one image and half another — it fails at boot, far from the
# cause. balena verifies by default; the dd path has to do it explicitly.

# sha256 of stdin. lib.sh's fm_verify_checksum covers files; a card is read as
# a stream, so the same two-tool detection is repeated for the stream case.
sha256_stream() {
  if fm_has_cmd sha256sum; then
    sha256sum | cut -d' ' -f1
  elif fm_has_cmd shasum; then
    shasum -a 256 | cut -d' ' -f1
  else
    fm_err "no sha256 tool found (sha256sum or shasum)"
    return 1
  fi
}

verify_card() {
  local raw size actual expected
  raw="$(raw_device)"
  size="$(wc -c <"$WORK_IMG" | tr -d ' ')"
  fm_log "verifying the card against the image"
  expected="$(sha256_stream <"$WORK_IMG")"
  # A short or failed read changes the hash, so the comparison below is the
  # error check — the pipeline's own exit status adds nothing.
  actual="$(sudo dd if="$raw" bs=16m 2>/dev/null | head -c "$size" | sha256_stream)"
  if [ "$actual" != "$expected" ]; then
    fm_err "the card does not match the image — it is not bootable"
    fm_info "re-seat the reader and run this again; a dropped USB link mid-write"
    fm_info "is the usual cause, and the card keeps a valid partition table"
    fm_info "over a half-written filesystem, which boots into confusing failures"
    return 1
  fi
  fm_ok "card matches the image"
}

# balena validates the write, so it is preferred — but only when its native
# modules actually load (Homebrew's bottle ships broken on some node/arch
# combinations). The probe exercises the flash subcommand, not just the binary,
# and any failure lands on dd, which needs nothing beyond the OS.
flash_image() {
  if fm_has_cmd balena && balena local flash --help >/dev/null 2>&1; then
    if flash_balena; then
      return 0 # balena verified the write itself
    fi
    fm_warn "balena failed — falling back to dd"
  fi
  if ! flash_dd; then
    fm_err "the write failed part-way — the card is not bootable"
    fm_info "a card that drops off the bus twice is failing, not glitching:"
    fm_info "try another reader, another port, and skip any hub"
    return 1
  fi
  verify_card
}

eject_card() {
  if [ "$(fm_detect_os)" = "macos" ]; then
    diskutil eject "$DEVICE" >/dev/null 2>&1 || true
  fi
}

# --- Plan -------------------------------------------------------------------

print_plan() {
  fm_banner
  fm_log "flash plan"
  fm_info "image     $(basename "$FM_JETSON_IMAGE_URL")"
  fm_info "device    ${DEVICE:-<required>}"
  fm_info "identity  $NEW_USER@$NEW_HOSTNAME (password login locked, SSH keys injected)"
  fm_info "card      $MACHINE_NAME · fleet $MACHINE_FLEET · $MACHINE_TRANSPORT · $MACHINE_WORKLOAD · ns $(fm_machine_namespace "$MACHINE_NAME")"
  fm_info "workspace $MACHINE_WORKSPACE"
  fm_info "wifi      ${WIFI_SSID:-none (Ethernet)}"
  if [ -n "$TS_AUTHKEY" ]; then
    fm_info "tailscale authkey provided"
  else
    fm_info "tailscale manual (sudo tailscale up --ssh)"
  fi
  if [ "$PROVISION" = 1 ]; then
    fm_info "boot      fm-setup --jetson${GH_TOKEN:+, then fm_ros2 --recorder --service}"
    # The two refs this card will carry. Printed because "reproducible" is a
    # claim about exactly these, and a plan that hides them cannot be checked
    # against the release anyone thinks they are flashing.
    local setup_ref ros2_ref
    setup_ref="${FM_SETUP_INSTALL_URL#"$FM_SETUP_RAW_BASE"/}"; setup_ref="${setup_ref%/install.sh}"
    ros2_ref="${FM_ROS2_INSTALL_URL#"$FM_ROS2_RAW_BASE"/}";   ros2_ref="${ros2_ref%/install.sh}"
    fm_info "refs      fm-setup $setup_ref · fm_ros2 $ros2_ref"
    [ -n "$GH_TOKEN" ] || fm_info "          (no --gh-token: recorder deferred to ~/NEXT-STEP.md)"
  else
    fm_info "boot      identity only (--no-provision)"
  fi
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --device)            DEVICE="${2:?--device needs a value}"; shift 2 ;;
      --name)              MACHINE_NAME="${2:?--name needs a value}"; NEW_HOSTNAME="$MACHINE_NAME"; shift 2 ;;
      --fleet)             MACHINE_FLEET="${2:?--fleet needs a value}"; shift 2 ;;
      --transport)         MACHINE_TRANSPORT="${2:?--transport needs a value}"; shift 2 ;;
      --workload)          MACHINE_WORKLOAD="${2:?--workload needs a value}"; shift 2 ;;
      --user)              NEW_USER="${2:?}"; shift 2 ;;
      --ssh-key)           SSH_KEY_FILE="${2:?}"; shift 2 ;;
      --wifi)
        case "${2:-}" in *:*) ;; *) fm_err "--wifi wants ssid:psk"; return 1 ;; esac
        WIFI_SSID="${2%%:*}"; WIFI_PSK="${2#*:}"; shift 2 ;;
      --tailscale-authkey) TS_AUTHKEY="${2:?}"; shift 2 ;;
      --gh-token)          GH_TOKEN="${2:?}"; shift 2 ;;
      --no-provision)      PROVISION=0; shift ;;
      --dry-run)           DRY_RUN=1; shift ;;
      -y|--yes)            ASSUME_YES=1; shift ;;
      -h|--help)           usage; return 0 ;;
      *) fm_err "unknown option: $1"; usage; return 1 ;;
    esac
  done

  require_sane_name hostname "$NEW_HOSTNAME"
  require_sane_name username "$NEW_USER"
  # The name is the card's primary key, so its shape is checked here rather
  # than discovered on the rig hours later by a doctor run nobody is watching.
  MACHINE_WORKSPACE="/home/$NEW_USER/fm"
  # Every card field is checked here, against the same validators `machine init`
  # uses, before any of them is written into the seed. This is the one card
  # nobody can correct afterwards: an unvalidated value goes onto the SD card
  # baked into /etc/fm/machine.json, and a value carrying a quote or a brace
  # would land as malformed JSON on a rig that is already in someone's hands.
  fm_machine_valid_name "$MACHINE_NAME" jetson
  fm_machine_valid_fleet "$MACHINE_FLEET"
  fm_machine_valid_transport "$MACHINE_TRANSPORT"
  MACHINE_WORKLOAD="$(fm_machine_workload_value "$MACHINE_WORKLOAD")"
  fm_machine_valid_workload "$MACHINE_WORKLOAD"
  fm_machine_valid_workspace "$MACHINE_WORKSPACE"
  # Both secrets are interpolated into the first-boot script, which runs as root
  # on the appliance, so a value carrying a quote closes the string it sits in
  # and the rest of it becomes commands. The card is already written by then and
  # the rig is in someone's hands, so this is checked before anything is staged.
  case "$GH_TOKEN" in *[!A-Za-z0-9_-]*) fm_err "--gh-token looks malformed"; return 1 ;; esac
  case "$TS_AUTHKEY" in *[!A-Za-z0-9_-]*) fm_err "--tailscale-authkey looks malformed"; return 1 ;; esac

  print_plan
  if [ "$DRY_RUN" = 1 ]; then
    fm_ok "dry run — nothing written"
    return 0
  fi

  [ -n "$DEVICE" ] || { fm_err "--device is required"; usage; return 1; }
  case "$(fm_detect_os)" in
    macos) validate_device_macos ;;
    linux) validate_device_linux ;;
  esac

  # Keys are the only door into the appliance — fail before the disk is erased.
  SSH_KEYS="$(collect_ssh_keys)"

  fetch_image
  clone_image
  stage_seed
  inject_seed
  confirm_erase
  flash_image
  eject_card

  fm_ok "insert the card and power the Jetson on"
  fm_info "first boot provisions unattended; follow it with:"
  fm_info "  ssh $NEW_USER@$NEW_HOSTNAME.local tail -f /var/log/fm-first-boot.log"
  fm_info "give it a few minutes: .local answers only once cloud-init has"
  fm_info "installed avahi. Before that, try the router's own DNS:"
  fm_info "  ssh $NEW_USER@$NEW_HOSTNAME"
  fm_info "or sweep the LAN for its lease, then read the address off the table:"
  fm_info "  for i in \$(seq 1 254); do (ping -c1 -W300 <prefix>.\$i >/dev/null 2>&1 &); done"
  fm_info "  arp -a | grep $NEW_HOSTNAME"
}

main "$@"
