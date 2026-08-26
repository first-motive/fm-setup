#!/usr/bin/env bash
#
# seed-workstation.sh — the autoinstall seed the GPU workstation installs from.
#
#   scripts/internal/seed-workstation.sh --out <dir> --name fm-ws-01 \
#     --authorized-keys <file> --setup-url <url> --ros2-url <url>
#
# Writes user-data and meta-data into <dir>. `./run.sh flash --role workstation`
# writes the pinned Ubuntu Desktop ISO to the stick raw and puts these two files
# on a second FAT partition labelled CIDATA, which is where the installer's
# cloud-init datasource looks for them.
#
# This file is the click-through install, written down. It replaces, in order:
#
#   language and keyboard             → locale, keyboard
#   "Interactive installation"        → the whole autoinstall block
#   "Default selection" + third-party → source, drivers
#   "Erase disk and install Ubuntu"   → storage.layout: direct
#   name / computer name / password   → identity
#   OpenSSH server, import GitHub key → ssh
#   reboot, then the two curl lines   → user-data's first-boot chain
#
# What it does not replace: one keypress. The ISO is written raw rather than
# remastered, so the boot menu still asks to confirm the autoinstall before it
# starts. Remastering with the `autoinstall` kernel argument would need xorriso
# in a container on macOS, and is tracked as its own issue.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$_here/../.." && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$FM_ROOT/lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$FM_ROOT/scripts/manifest.sh"
# shellcheck source=./seed-lib.sh disable=SC1091
. "$_here/seed-lib.sh"

ROLE=workstation

# The installer will not create an account without one, and refuses a plaintext
# password outright. Only this role has it: the jetson's appliance account is
# locked (`lock_passwd: true`) and reached by key alone, while a workstation is a
# box someone sits at and has to be able to log into at the console.
#
# Defaults from the environment, so the hash does not reach shell history or the
# process table. Generate one with:
#   mkpasswd --method=SHA-512 --rounds=4096
SEED_PASSWORD_HASH="${FM_FLASH_PASSWORD_HASH:-}"

usage() {
  cat <<EOF
seed-workstation.sh — the autoinstall seed the GPU workstation installs from

Usage: scripts/internal/seed-workstation.sh --out <dir> [options]

$(fm_seed_usage_common)
  --password-hash <hash>   console password, already hashed (or set
                           FM_FLASH_PASSWORD_HASH, which keeps it out of the
                           process table)
EOF
}

# --- Seed files -------------------------------------------------------------

# The cloud-config the installed system runs on its own first boot, nested inside
# the answer file as autoinstall's `user-data`.
#
# Nested rather than run as a late-command: a late-command runs inside the
# installer's environment against a half-built target, where there is no network
# stack of the target's own and no systemd to hang a unit on. The provisioning
# chain wants a booted machine, which is exactly what this key gives it.
build_nested_user_data() {
  cat <<EOF
    write_files:
      - path: $FM_MACHINE_FILE_LINUX
        permissions: "0644"
        content: |
$(fm_seed_card "$ROLE" "          ")
EOF
  if [ "$SEED_PROVISION" = 1 ]; then
    cat <<EOF
      - path: /usr/local/sbin/fm-first-boot.sh
        permissions: "0700"
        content: |
EOF
    fm_seed_first_boot "$ROLE" | sed 's/^/          /'
    cat <<EOF
    runcmd:
      - [bash, /usr/local/sbin/fm-first-boot.sh]
EOF
  fi
}

build_user_data() {
  cat <<EOF
#cloud-config
# Seeded by fm-setup (./run.sh flash --role workstation). One workstation, no
# wizard: every answer the desktop installer would ask for is below.
autoinstall:
  version: 1
  # Empty rather than absent: an interactive section is a screen the installer
  # stops on, and this stick is meant to be left alone once it boots.
  interactive-sections: []
  locale: en_US.UTF-8
  keyboard:
    layout: us
  identity:
    hostname: $SEED_HOSTNAME
    username: $SEED_USER
    realname: First Motive
    password: $(fm_seed_yaml_quote "$SEED_PASSWORD_HASH")
  ssh:
    install-server: true
    # The keys below are the way in. Password login stays off, so a weak console
    # password cannot become a network-reachable one.
    allow-pw: false
    authorized-keys:
$(fm_seed_authorized_keys_yaml "      ")
  storage:
    # The installer's own default disk, wiped. --target-disk is deliberately not
    # a flag: this role runs on one box with one system drive, and a mis-typed
    # disk here erases the wrong one with nobody watching.
    layout:
      name: direct
  source:
    # The minimal desktop: a session, a browser, and nothing else. rviz, Isaac
    # Sim, and the annotation tooling all arrive through the role's own steps.
    id: ubuntu-desktop-minimal
    search_drivers: true
  # Empty on purpose. The snap-free workstation is a step (25-no-snap.sh), which
  # also converges a machine installed before this seed existed; this line only
  # keeps the installer from putting any back on the way in.
  snaps: []
  packages: [curl, git, avahi-daemon, libnss-mdns]
  user-data:
$(build_nested_user_data)
EOF
}

main() {
  fm_seed_parse_args "$@"

  local i=0
  while [ "$i" -lt "${#SEED_REST[@]}" ]; do
    case "${SEED_REST[$i]}" in
      --password-hash)
        SEED_PASSWORD_HASH="${SEED_REST[$((i + 1))]:-}"; i=$((i + 2)) ;;
      -h|--help) usage; return 0 ;;
      *) fm_err "unknown option: ${SEED_REST[$i]}"; usage; return 1 ;;
    esac
  done

  fm_seed_require "$ROLE"

  [ -n "$SEED_PASSWORD_HASH" ] || {
    fm_err "a password hash is required — the installer will not create an account without one"
    fm_info "generate one with: mkpasswd --method=SHA-512 --rounds=4096"
    fm_info "then: export FM_FLASH_PASSWORD_HASH=…  (or pass --password-hash)"
    return 1
  }
  # A plaintext password here would be written to the answer file and accepted by
  # the installer as the account's literal password, which is worse than the
  # refusal: it looks like it worked. Every crypt hash starts with $<id>$.
  case "$SEED_PASSWORD_HASH" in
    '$'*'$'*) ;;
    *) fm_err "--password-hash does not look like a crypt hash (expected \$6\$…)"; return 1 ;;
  esac

  build_user_data >"$SEED_OUT/user-data"
  # Required, however little it says: cloud-init's NoCloud datasource ignores a
  # volume with no meta-data on it at all, however good its user-data.
  #
  # `instance-id`, hyphenated, is cloud-init's own spelling. seed-jetson.sh
  # writes `instance_id` and stays that way on purpose: that seed is proven on
  # the rigs already in the field, and cloud-init accepts both, so the spelling
  # is not worth re-proving on hardware to make two files match.
  cat >"$SEED_OUT/meta-data" <<EOF
instance-id: $SEED_HOSTNAME
EOF
}

main "$@"
