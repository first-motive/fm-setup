#!/usr/bin/env bash
#
# flash — build provisioned boot media, from the machine with the slot.
#
#   ./run.sh flash --device /dev/disk4                            # a capture rig
#   ./run.sh flash --role workstation --device /dev/disk4 \
#     --name fm-ws-01                                             # the workstation
#
# Writes the role's pinned image (scripts/manifest.sh) and puts a seed on the
# media that answers everything the first boot would otherwise ask: hostname,
# user, SSH keys, the identity card, and a first-boot script that chains this
# repo's role and — with --gh-token — fm_ros2's workspace layer. The media comes
# out of this script ready to boot into a provisioned machine.
#
# The two roles put the seed in different places, because their images differ:
#
#   jetson       a raw .img whose ext4 rootfs carries a baked NoCloud seed
#                (/var/lib/cloud/seed/nocloud), which beats any file laid on the
#                FAT partition. So the image is cloned, the rootfs loop-mounted
#                at the pinned offset, the seed swapped, and the clone written.
#                On macOS that ext4 mount happens inside a privileged container
#                (OrbStack/Docker); on Linux it is a plain loop mount.
#
#   workstation  an ISO, whose filesystem is read-only. It is written raw and a
#                second FAT partition labelled CIDATA is added after it, which
#                is where the desktop installer's cloud-init looks. Nothing is
#                remastered, so the boot menu still asks once before the
#                autoinstall starts — the one keypress a rebuild needs.
#
# Engine: balena CLI when present (validates after write), otherwise dd. The
# target must be a whole, external disk — internal disks are refused outright.
#
# Firmware prerequisite for the jetson, documented not automated: the board's
# QSPI must carry NVIDIA's r36.x UEFI firmware. Any Orin that has booted
# JetPack 6 qualifies.

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
# Where the cache may live, checked before anything uses it.
#
# On macOS this directory is bind-mounted into a privileged container for the
# jetson's ext4 seed swap, which is a container with the host's device nodes in
# reach. FM_FLASH_CACHE pointing at /dev, /etc, or / would hand it those. This
# is not a privilege boundary — whoever sets the variable already runs the sudo
# below — but a cache directory has one shape, and a value with another shape is
# a mistake worth refusing rather than mounting.
require_sane_cache_dir() {
  case "$CACHE_DIR" in
    /*) ;;
    *) fm_err "FM_FLASH_CACHE must be an absolute path: '$CACHE_DIR'"; return 1 ;;
  esac
  case "$CACHE_DIR" in
    /|/dev|/dev/*|/etc|/etc/*|/proc|/proc/*|/sys|/sys/*|/boot|/boot/*|/usr|/usr/*|/bin|/bin/*|/sbin|/sbin/*|/lib|/lib/*|/root|/root/*)
      fm_err "FM_FLASH_CACHE may not be a system directory: '$CACHE_DIR'"
      fm_info "it is bind-mounted into a privileged container on macOS"
      return 1 ;;
  esac
}
# Resolved from the role once it is known — see resolve_role.
IMAGE_URL=""
IMAGE_SHA256=""
IMAGE_DOWNLOAD=""
IMAGE_RAW=""
WORK_IMG=""
# The working image is a throwaway clone for the jetson and the cached image
# itself for the workstation, and only the first may be deleted on the way out.
WORK_IS_CLONE=0
SEED_DIR=""
CIDATA_LABEL=CIDATA

ROLE=jetson
DEVICE=""
# The card decides the hostname, not the other way round: a machine's name, its
# mDNS name, and the stem of its ROS namespace are one fact, seeded here so the
# machine boots already knowing which one it is. Empty until the role is known,
# because the abbreviation follows the role; 01 is a default the second machine
# of a role must override — two cards claiming fm-rec-01 collide on the LAN
# exactly as the old singular fm-jetson did.
MACHINE_NAME=""
MACHINE_FLEET="$FM_MACHINE_FLEET_DEFAULT"
MACHINE_TRANSPORT="${FM_MACHINE_TRANSPORTS[0]}"
# Also empty until the role is known. A flashed card is a capture rig, so the
# jetson defaults to recorder; a workstation runs no bridge and defaults to none,
# which is the same answer `machine init` gives on a machine with no workload.
MACHINE_WORKLOAD=""
# One visible parent directory for every checkout, resolved once --user is
# known. Consumers read this out of the card rather than assuming a path.
MACHINE_WORKSPACE=""
NEW_HOSTNAME=""
NEW_USER="$FM_FLASH_USER"
WIFI_SSID=""
WIFI_PSK=""
# Secrets default from the environment, which keeps them out of shell history
# and out of the process table. A flag still overrides, for a scripted caller.
TS_AUTHKEY="${FM_TS_AUTHKEY:-}"
GH_TOKEN="${FM_GH_TOKEN:-}"
PASSWORD_HASH="${FM_FLASH_PASSWORD_HASH:-}"
SSH_KEY_FILE=""
SSH_KEYS=""
PROVISION=1
DRY_RUN=0
ASSUME_YES=0

usage() {
  cat <<EOF
flash — build provisioned boot media for a role

Usage: ./run.sh flash [--role <role>] --device <disk> [options]

  --role <role>            jetson (default) or workstation. Picks the image,
                           the seed schema, and the first-boot install chain.
  --device <disk>          target disk, whole device (macOS /dev/diskN,
                           Linux /dev/sdX). Internal disks are refused.
  --name <fm-xx-nn>        machine name, which is also the hostname, the mDNS
                           name, and the stem of the ROS namespace
                           (default: fm-rec-01 / fm-ws-01 — override on the
                           second machine of a role)
  --fleet <name>           population this machine joins (default: $MACHINE_FLEET)
  --transport <profile>    middleware profile (default: $MACHINE_TRANSPORT)
  --workload <kind>        what the machine does, or none (default: recorder on
                           the jetson, none on the workstation)
  --user <name>            the account the machine answers on (default: $FM_FLASH_USER)
  --ssh-key <file>         public key to authorize (default: every ~/.ssh/*.pub)
  --password-hash <hash>   console password, already hashed — workstation only,
                           and required there. Prefer FM_FLASH_PASSWORD_HASH.
                           Linux: mkpasswd --method=SHA-512 --rounds=4096
                           macOS: openssl passwd -6
  --wifi <ssid:psk>        join this network on boot — jetson only
  --tailscale-authkey <k>  join the tailnet on first boot (use an ephemeral key).
                           Prefer FM_TS_AUTHKEY, for the reason below.
  --gh-token <token>       read-only fine-grained PAT for the private overlays;
                           with it, the workspace layer installs unattended.
                           Prefer FM_GH_TOKEN (below) — an argument is visible
                           in the process table and in shell history.
  --no-provision           identity only — skip the first-boot install chain
  --dry-run                print the plan, touch nothing
  -y, --yes                skip the erase confirmation

macOS needs a container runtime (OrbStack or Docker) for the jetson's seed swap
— the rootfs is ext4 — and sgdisk for the workstation's seed partition, which
this script installs itself (brew install gptfdisk) when Homebrew is present.
Linux needs sgdisk and sudo.

Read a secret from the environment instead of the command line, so it reaches
neither shell history nor the process table:

  read -rs FM_GH_TOKEN && export FM_GH_TOKEN
  read -rs FM_TS_AUTHKEY && export FM_TS_AUTHKEY
  read -rs FM_FLASH_PASSWORD_HASH && export FM_FLASH_PASSWORD_HASH
  ./run.sh flash --device <disk> -y

Every secret passed here lands in the seed in plain text until first boot
consumes it. Hand the media straight to the machine, and prefer
ephemeral/least-scope credentials.

First boot takes 15-30 min on the provisioning chain. Watch it:
  ssh $FM_FLASH_USER@<name>.local tail -f /var/log/fm-first-boot.log
EOF
}

# --- Small helpers ----------------------------------------------------------

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
  # The cached image carries none and is expensive to fetch again, so only a
  # clone is removed here.
  if [ "$WORK_IS_CLONE" = 1 ] && [ -n "$WORK_IMG" ]; then rm -f "$WORK_IMG"; fi
  if [ -n "$SEED_DIR" ]; then rm -rf "$SEED_DIR"; fi
}
# INT/TERM/HUP as well as EXIT: a closed terminal during the long write or the
# equally long read-back would otherwise strand a 5 GB working image that
# carries the baked token in plain text.
trap cleanup EXIT INT TERM HUP

# --- Role -------------------------------------------------------------------

# Resolve everything the role decides, before anything else reads it.
#
# The image pins are looked up by name rather than through a case, so a role
# added to the manifest is a role this verb can already flash. A role with no pin
# fails here, loudly, rather than resolving to some other role's image.
resolve_role() {
  fm_machine_valid_role "$ROLE" || return 1
  case "$ROLE" in
    jetson|workstation) ;;
    *) fm_err "role '$ROLE' has no image to flash (jetson|workstation)"; return 1 ;;
  esac

  local upper url_var sha_var
  upper="$(printf '%s' "$ROLE" | tr '[:lower:]' '[:upper:]')"
  url_var="FM_IMAGE_URL_$upper"
  sha_var="FM_IMAGE_SHA256_$upper"
  IMAGE_URL="${!url_var:-}"
  IMAGE_SHA256="${!sha_var:-}"
  if [ -z "$IMAGE_URL" ] || [ -z "$IMAGE_SHA256" ]; then
    fm_err "no image pinned for role '$ROLE' — add $url_var and $sha_var to the manifest"
    return 1
  fi

  IMAGE_DOWNLOAD="$CACHE_DIR/$(basename "$IMAGE_URL")"
  # Only the Jetson image is compressed. An ISO is written exactly as it arrives,
  # so there is nothing to decompress and nothing to cache twice.
  case "$IMAGE_DOWNLOAD" in
    *.xz) IMAGE_RAW="${IMAGE_DOWNLOAD%.xz}" ;;
    *)    IMAGE_RAW="$IMAGE_DOWNLOAD" ;;
  esac

  [ -n "$MACHINE_NAME" ] || MACHINE_NAME="fm-$(fm_machine_abbrev "$ROLE")-01"
  NEW_HOSTNAME="$MACHINE_NAME"
  if [ -z "$MACHINE_WORKLOAD" ]; then
    case "$ROLE" in
      jetson)      MACHINE_WORKLOAD=recorder ;;
      workstation) MACHINE_WORKLOAD=none ;;
    esac
  fi
}

# --- Image ------------------------------------------------------------------

fetch_image() {
  mkdir -p "$CACHE_DIR"
  if [ ! -f "$IMAGE_DOWNLOAD" ] || ! fm_verify_checksum "$IMAGE_DOWNLOAD" "$IMAGE_SHA256" 2>/dev/null; then
    fm_log "downloading $(basename "$IMAGE_URL")"
    curl -fSL --proto '=https' -C - -o "$IMAGE_DOWNLOAD" "$IMAGE_URL"
    fm_verify_checksum "$IMAGE_DOWNLOAD" "$IMAGE_SHA256"
    # A fresh download invalidates the cached decompression, where there is one.
    [ "$IMAGE_RAW" = "$IMAGE_DOWNLOAD" ] || rm -f "$IMAGE_RAW"
  fi
  fm_ok "image verified against the pinned sha256"
  if [ "$IMAGE_RAW" != "$IMAGE_DOWNLOAD" ] && [ ! -f "$IMAGE_RAW" ]; then
    fm_log "decompressing (cached for the next flash)"
    fm_require_cmd xz
    xz -dk "$IMAGE_DOWNLOAD"
  fi
}

# Clone the cached image for this card. On APFS the clone is copy-on-write and
# instant; elsewhere it is a plain copy.
clone_image() {
  WORK_IMG="$CACHE_DIR/.flash-$$.img"
  WORK_IS_CLONE=1
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
  fm_confirm "erase $DEVICE and write the $ROLE image?" || {
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
    fm_info "the seed locks password login, so a key is the only door in"
    return 1
  }
  printf '%s' "$keys"
}

# Stage the seed files, secrets included, under a 0700 dir the EXIT trap
# removes. What goes in them is the role's business, not this script's: each
# schema lives in scripts/internal/seed-<role>.sh, which CI can build and
# validate on its own rather than only through a 5 GB image write.
#
# The two secrets travel in the environment rather than on the command line,
# because an argument to a child process is readable from the process table by
# any local account for as long as the child lives.
stage_seed() {
  SEED_DIR="$(mktemp -d "$CACHE_DIR/.seed.XXXXXX")"
  chmod 700 "$SEED_DIR"
  local keys_file="$SEED_DIR/.authorized-keys"
  ( umask 077; printf '%s' "$SSH_KEYS" >"$keys_file" )

  local args=(
    --out "$SEED_DIR"
    --name "$MACHINE_NAME"
    --user "$NEW_USER"
    --fleet "$MACHINE_FLEET"
    --transport "$MACHINE_TRANSPORT"
    --workspace "$MACHINE_WORKSPACE"
    --authorized-keys "$keys_file"
    --setup-url "$FM_SETUP_INSTALL_URL"
    --ros2-url "$FM_ROS2_INSTALL_URL"
  )
  if [ -n "$MACHINE_WORKLOAD" ]; then args+=(--workload "$MACHINE_WORKLOAD"); fi
  if [ "$PROVISION" != 1 ]; then args+=(--no-provision); fi

  FM_GH_TOKEN="$GH_TOKEN" \
  FM_TS_AUTHKEY="$TS_AUTHKEY" \
  FM_FLASH_WIFI="${WIFI_SSID:+$WIFI_SSID:$WIFI_PSK}" \
  FM_FLASH_PASSWORD_HASH="$PASSWORD_HASH" \
    bash "$FM_ROOT/scripts/internal/seed-$ROLE.sh" "${args[@]}"

  # The keys are in user-data by now; the staging copy is not seed content and
  # must not reach the card.
  rm -f "$keys_file"
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

# --- The CIDATA partition ---------------------------------------------------
#
# The workstation's half. An ISO's filesystem is read-only, so its seed cannot be
# swapped the way the Jetson's is; it rides in a FAT partition added after the
# written ISO, which is where cloud-init's NoCloud datasource looks for a volume
# labelled CIDATA.
#
# sgdisk rather than each platform's own partition editor, because the two would
# otherwise disagree about a table this delicate: an isohybrid ISO puts its
# backup GPT header at the end of the *image*, not the end of the stick, and
# `sgdisk -e` is the one command that moves it before a partition is appended.

# Echo the number of the last partition on DEVICE — the one just appended.
#
# Checked for shape rather than trusted: this number becomes a device path that
# is handed to mkfs and to mount, and sgdisk printing something unexpected —
# because the table is corrupt, or because stderr arrived on stdout — should
# stop the run rather than name a device nobody meant.
last_part_number() {
  local n
  n="$(sudo sgdisk --print "$DEVICE" | awk '/^ *[0-9]+ / { last = $1 } END { print last }')"
  case "$n" in
    ""|*[!0-9]*) fm_err "could not read a partition number from sgdisk: '${n:-<empty>}'"; return 1 ;;
  esac
  printf '%s\n' "$n"
}

# Echo the device node of partition N on DEVICE.
part_node() {
  local n="$1"
  if [ "$(fm_detect_os)" = "macos" ]; then
    printf '%ss%s\n' "$DEVICE" "$n"
  elif [ -b "${DEVICE}${n}" ]; then
    printf '%s%s\n' "$DEVICE" "$n"
  else
    printf '%sp%s\n' "$DEVICE" "$n"
  fi
}

unmount_disk() {
  if [ "$(fm_detect_os)" = "macos" ]; then
    diskutil unmountDisk force "$DEVICE" >/dev/null
  else
    sudo umount "${DEVICE}"?* 2>/dev/null || true
  fi
}

# The one dependency this verb installs rather than names: the Mac driving a
# rebuild has Homebrew as its assumed package manager already (see fm_has_docker
# and the OrbStack hint above), so a missing sgdisk is a brew invocation away —
# stopping to make the operator type it is exactly the by-hand step a rebuild
# should not have (#42). Without brew there is nothing to install with, so both
# missing pieces are named. Linux keeps the plain error: package managers vary
# and apt under sudo is not this script's call to make.
require_sgdisk() {
  fm_has_cmd sgdisk && return 0
  if [ "$(fm_detect_os)" = "macos" ] && fm_has_cmd brew; then
    fm_log "sgdisk is missing — installing gptfdisk with Homebrew"
    brew install gptfdisk
    fm_require_cmd sgdisk || return 1
  else
    fm_err "missing dependency: sgdisk — and no Homebrew (brew) here to install it"
    fm_info "macOS: install Homebrew, then brew install gptfdisk · Debian/Ubuntu: apt install gdisk"
    return 1
  fi
}

append_cidata() {
  require_sgdisk || return 1
  fm_log "adding the $CIDATA_LABEL seed partition"
  unmount_disk

  # -e first: the ISO's backup GPT sits at the end of the image, and a partition
  # appended before it is moved lands outside the table the firmware reads.
  sudo sgdisk -e "$DEVICE" >/dev/null
  sudo sgdisk --new "0:0:+${FM_FLASH_CIDATA_SIZE_MB}M" \
    --typecode 0:0700 --change-name "0:$CIDATA_LABEL" "$DEVICE" >/dev/null

  local node
  node="$(part_node "$(last_part_number)")" || return 1

  if [ "$(fm_detect_os)" = "macos" ]; then
    diskutil unmountDisk force "$DEVICE" >/dev/null
    # -F 16: a 64 MB volume is small enough that newfs_msdos would otherwise pick
    # FAT12, which cloud-init's datasource does not look at.
    sudo newfs_msdos -F 16 -v "$CIDATA_LABEL" "/dev/r${node#/dev/}" >/dev/null
  else
    sudo partprobe "$DEVICE" 2>/dev/null || true
    sudo mkfs.vfat -F 16 -n "$CIDATA_LABEL" "$node" >/dev/null
  fi

  copy_seed_to "$node"
  fm_ok "seed carries $NEW_USER@$NEW_HOSTNAME on $CIDATA_LABEL"
}

# Mount the CIDATA partition at a temp path, run CMD with it, unmount. Both the
# copy and the read-back verify want exactly this, and a mount left behind on a
# stick someone is about to unplug is its own small disaster.
with_cidata() {
  local node="$1"; shift
  local mnt rc=0
  mnt="$(mktemp -d)"
  if [ "$(fm_detect_os)" = "macos" ]; then
    diskutil mount -mountPoint "$mnt" "$node" >/dev/null
  else
    sudo mount "$node" "$mnt"
  fi
  "$@" "$mnt" || rc=$?
  sync
  if [ "$(fm_detect_os)" = "macos" ]; then
    diskutil unmount "$mnt" >/dev/null 2>&1 || true
  else
    sudo umount "$mnt" 2>/dev/null || true
  fi
  rmdir "$mnt" 2>/dev/null || true
  return "$rc"
}

copy_seed_files() {
  local mnt="$1"
  sudo cp "$SEED_DIR/user-data" "$SEED_DIR/meta-data" "$mnt/"
}

copy_seed_to() { with_cidata "$1" copy_seed_files; }

compare_seed_files() {
  local mnt="$1" f
  for f in user-data meta-data; do
    cmp -s "$SEED_DIR/$f" "$mnt/$f" || {
      fm_err "$f on the stick does not match what was staged"
      return 1
    }
  done
}

# Read the seed back off the stick. The ISO region is hashed like any other
# write; this is the half of the media that dd never saw, so it is compared
# file by file instead.
verify_cidata() {
  local node
  node="$(part_node "$(last_part_number)")" || return 1
  fm_log "verifying the seed partition"
  with_cidata "$node" compare_seed_files || return 1
  fm_ok "$CIDATA_LABEL carries the staged seed"
}

# Put the seed where the role's image expects to find it.
place_seed() {
  case "$ROLE" in
    jetson)      inject_seed ;;
    workstation) append_cidata ;;
  esac
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
  # error check — the pipeline's own exit status adds nothing. It subtracts,
  # in fact: `head` closes the pipe at $size, dd dies of SIGPIPE, and under
  # `pipefail` + `errexit` that killed this whole script here with no message,
  # no "card matches", and no seed partition (fm-ws-01, 2026-08-27). Read
  # exactly the image's bytes instead so dd ends on its own, and keep the
  # `|| true` so a stray signal still lands in the hash comparison, not here.
  actual="$( { sudo dd if="$raw" bs=1048576 count="$(( (size + 1048575) / 1048576 ))" 2>/dev/null || true; } \
             | head -c "$size" | sha256_stream)"
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
    fm_err "the write failed part-way — the media is not bootable"
    fm_info "media that drops off the bus twice is failing, not glitching:"
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

# One line naming where this role's seed ends up, because it is the difference
# between the two roles a person has to know about: one boots straight through,
# the other asks once.
seed_placement_summary() {
  case "$ROLE" in
    jetson)      printf 'swapped into the image rootfs (NoCloud)\n' ;;
    workstation) printf "%s partition after the ISO, %s MB (confirm once at boot)\n" \
                   "$CIDATA_LABEL" "$FM_FLASH_CIDATA_SIZE_MB" ;;
  esac
}

print_plan() {
  local workspace_flag
  workspace_flag="$(fm_flash_workspace_flag "$ROLE")"
  fm_banner
  fm_log "flash plan"
  fm_info "role      $ROLE"
  fm_info "image     $(basename "$IMAGE_URL")"
  fm_info "device    ${DEVICE:-<required>}"
  fm_info "identity  $NEW_USER@$NEW_HOSTNAME (password login locked, SSH keys injected)"
  fm_info "card      $MACHINE_NAME · fleet $MACHINE_FLEET · $MACHINE_TRANSPORT · ${MACHINE_WORKLOAD:-none} · ns $(fm_machine_namespace "$MACHINE_NAME")"
  fm_info "workspace $MACHINE_WORKSPACE"
  fm_info "seed      $(seed_placement_summary)"
  if [ "$ROLE" = jetson ]; then
    fm_info "wifi      ${WIFI_SSID:-none (Ethernet)}"
  fi
  if [ -n "$TS_AUTHKEY" ]; then
    fm_info "tailscale authkey provided"
  else
    fm_info "tailscale manual (sudo tailscale up --ssh)"
  fi
  if [ "$PROVISION" = 1 ]; then
    fm_info "boot      fm-setup --$ROLE${GH_TOKEN:+, then fm_ros2 $workspace_flag --service}"
    # The two refs this card will carry. Printed because "reproducible" is a
    # claim about exactly these, and a plan that hides them cannot be checked
    # against the release anyone thinks they are flashing.
    local setup_ref ros2_ref
    setup_ref="${FM_SETUP_INSTALL_URL#"$FM_SETUP_RAW_BASE"/}"; setup_ref="${setup_ref%/install.sh}"
    ros2_ref="${FM_ROS2_INSTALL_URL#"$FM_ROS2_RAW_BASE"/}";   ros2_ref="${ros2_ref%/install.sh}"
    fm_info "refs      fm-setup $setup_ref · fm_ros2 $ros2_ref"
    [ -n "$GH_TOKEN" ] || fm_info "          (no --gh-token: workspace layer deferred to ~/NEXT-STEP.md)"
  else
    fm_info "boot      identity only (--no-provision)"
  fi
}

# Everything a bad flag can be caught on, before anything is fetched, staged, or
# erased. Returns 2 throughout: a rejected value is a usage error, and `fm`'s
# exit-code contract keeps that distinct from a run that failed part-way.
validate_request() {
  require_sane_cache_dir || return 2
  resolve_role || return 2
  require_sane_name hostname "$NEW_HOSTNAME" || return 2
  require_sane_name username "$NEW_USER" || return 2
  MACHINE_WORKSPACE="/home/$NEW_USER/fm"

  # Every card field is checked here, against the same validators `machine init`
  # uses, before any of them is written into the seed. This is the one card
  # nobody can correct afterwards: an unvalidated value goes onto the media
  # baked into /etc/fm/machine.json, and a value carrying a quote or a brace
  # would land as malformed JSON on a machine already in someone's hands.
  #
  # The name is checked against the role, not on its own: a card calling itself
  # fm-ws-01 while claiming to be a jetson puts a recorder's topics under the
  # workstation's namespace, which is invisible until nothing subscribes.
  fm_machine_valid_name "$MACHINE_NAME" "$ROLE" || return 2
  fm_machine_valid_fleet "$MACHINE_FLEET" || return 2
  fm_machine_valid_transport "$MACHINE_TRANSPORT" || return 2
  MACHINE_WORKLOAD="$(fm_machine_workload_value "$MACHINE_WORKLOAD")"
  fm_machine_valid_workload "$MACHINE_WORKLOAD" || return 2
  fm_machine_valid_workspace "$MACHINE_WORKSPACE" || return 2

  # Both secrets are interpolated into the first-boot script, which runs as root
  # on the machine, so a value carrying a quote closes the string it sits in and
  # the rest of it becomes commands. The card is already written by then and the
  # machine is in someone's hands, so this is checked before anything is staged.
  case "$GH_TOKEN" in *[!A-Za-z0-9_-]*) fm_err "--gh-token looks malformed"; return 2 ;; esac
  case "$TS_AUTHKEY" in *[!A-Za-z0-9_-]*) fm_err "--tailscale-authkey looks malformed"; return 2 ;; esac

  # A flag that belongs to the other role is a mistake worth naming. Silently
  # ignoring it would flash a wired workstation that its operator believes has
  # wifi credentials on it.
  if [ "$ROLE" != jetson ] && [ -n "$WIFI_SSID" ]; then
    fm_err "--wifi is jetson only — the workstation is a wired box"
    return 2
  fi
  if [ "$ROLE" = jetson ] && [ -n "$PASSWORD_HASH" ]; then
    fm_err "--password-hash is workstation only — the rig's account is locked and key-only"
    return 2
  fi
  # The seed builder refuses a missing or plaintext hash too. Saying so here as
  # well means a --dry-run reports it, rather than a person discovering it after
  # the image has downloaded.
  if [ "$ROLE" = workstation ] && [ "$PROVISION" = 1 ] && [ -z "$PASSWORD_HASH" ]; then
    fm_err "the workstation needs a console password: set FM_FLASH_PASSWORD_HASH or pass --password-hash"
    fm_info "generate one with: mkpasswd --method=SHA-512 --rounds=4096 (Linux) or openssl passwd -6 (macOS)"
    return 2
  fi
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --role)              ROLE="${2:?--role needs a value}"; shift 2 ;;
      --device)            DEVICE="${2:?--device needs a value}"; shift 2 ;;
      --name)              MACHINE_NAME="${2:?--name needs a value}"; shift 2 ;;
      --fleet)             MACHINE_FLEET="${2:?--fleet needs a value}"; shift 2 ;;
      --transport)         MACHINE_TRANSPORT="${2:?--transport needs a value}"; shift 2 ;;
      --workload)          MACHINE_WORKLOAD="${2:?--workload needs a value}"; shift 2 ;;
      --user)              NEW_USER="${2:?}"; shift 2 ;;
      --ssh-key)           SSH_KEY_FILE="${2:?}"; shift 2 ;;
      --password-hash)     PASSWORD_HASH="${2:?}"; shift 2 ;;
      --wifi)
        case "${2:-}" in *:*) ;; *) fm_err "--wifi wants ssid:psk"; return 2 ;; esac
        WIFI_SSID="${2%%:*}"; WIFI_PSK="${2#*:}"; shift 2 ;;
      --tailscale-authkey) TS_AUTHKEY="${2:?}"; shift 2 ;;
      --gh-token)          GH_TOKEN="${2:?}"; shift 2 ;;
      --no-provision)      PROVISION=0; shift ;;
      --dry-run)           DRY_RUN=1; shift ;;
      -y|--yes)            ASSUME_YES=1; shift ;;
      -h|--help)           usage; return 0 ;;
      *) fm_err "unknown option: $1"; usage; return 2 ;;
    esac
  done

  validate_request || return $?

  print_plan
  if [ "$DRY_RUN" = 1 ]; then
    fm_ok "dry run — nothing written"
    return 0
  fi

  [ -n "$DEVICE" ] || { fm_err "--device is required"; usage; return 2; }
  case "$(fm_detect_os)" in
    macos) validate_device_macos ;;
    linux) validate_device_linux ;;
  esac

  # Keys are the only door in — fail before the disk is erased.
  SSH_KEYS="$(collect_ssh_keys)"

  fetch_image
  stage_seed

  # The jetson's seed goes into the image before the write; the workstation's
  # goes onto the media after it, because an ISO is written exactly as it came.
  if [ "$ROLE" = jetson ]; then
    clone_image
    place_seed
    confirm_erase
    flash_image
  else
    WORK_IMG="$IMAGE_RAW"
    confirm_erase
    flash_image
    place_seed
    verify_cidata
  fi
  eject_card

  report_next_steps
}

report_next_steps() {
  if [ "$ROLE" = workstation ]; then
    fm_ok "boot the workstation from this stick and confirm the autoinstall once"
    fm_info "pick it from the firmware's boot menu, answer the one prompt, then leave it:"
    fm_info "the install, the reboot, and both provisioning layers run unattended"
  else
    fm_ok "insert the card and power the Jetson on"
    fm_info "first boot provisions unattended; follow it with:"
  fi
  fm_info "  ssh $NEW_USER@$NEW_HOSTNAME.local tail -f /var/log/fm-first-boot.log"
  fm_info "give it a few minutes: .local answers only once cloud-init has"
  fm_info "installed avahi. Before that, try the router's own DNS:"
  fm_info "  ssh $NEW_USER@$NEW_HOSTNAME"
  fm_info "or sweep the LAN for its lease, then read the address off the table:"
  fm_info "  for i in \$(seq 1 254); do (ping -c1 -W300 <prefix>.\$i >/dev/null 2>&1 &); done"
  fm_info "  arp -a | grep $NEW_HOSTNAME"
}

main "$@"
