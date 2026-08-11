#!/usr/bin/env bash
#
# add-user — give someone an account on this machine.
#
#   ./run.sh add-user matt
#
# The account gets a home directory, the shared `fm` group, and nothing else. No
# sudo: this machine has one administrator, the account that provisioned it, and
# everything that changes the host goes through an fm-setup step instead.
#
# No password is set, which leaves the account locked for console and password
# SSH login. Access is Tailscale SSH — one less credential to leak, and no
# password to hand over.
#
# The machine's CLAUDE.md reaches the new home through /etc/skel, which the
# agent-ruleset step populates during provisioning. Run that step first.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$_here/../.." && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$FM_ROOT/lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$FM_ROOT/scripts/manifest.sh"

usage() {
  cat <<'EOF'
add-user — create an account in the fm group, without sudo

Usage: ./run.sh add-user <name> [<name>…]
       ./run.sh add-user --help

The account is created with a home directory, the fm group, and no password:
it logs in over Tailscale SSH. To remove someone later:

  sudo deluser --remove-home <name>
EOF
}

# A username the system will accept, and that cannot smuggle anything into the
# commands below.
valid_name() {
  case "$1" in
    [a-z_][a-z0-9_-]*) [ "${#1}" -le 32 ] ;;
    *) return 1 ;;
  esac
}

add_one() {
  local user="$1"

  if ! valid_name "$user"; then
    fm_err "invalid username: '$user' (lowercase, starts with a letter or underscore, max 32 chars)"
    return 1
  fi

  if id -u "$user" >/dev/null 2>&1; then
    fm_ok "$user already exists"
  else
    fm_log "creating $user"
    sudo useradd --create-home --shell /bin/bash "$user"
  fi

  if id -nG "$user" | tr ' ' '\n' | grep -qx "$FM_GROUP"; then
    fm_ok "$user is in $FM_GROUP"
  else
    sudo usermod -aG "$FM_GROUP" "$user"
    fm_ok "$user added to $FM_GROUP"
  fi

  if id -nG "$user" | tr ' ' '\n' | grep -qx sudo; then
    fm_warn "$user is in the sudo group — this machine is meant to have one administrator"
    fm_info "remove it deliberately with: sudo gpasswd -d $user sudo"
  fi

  fm_ok "$user can now reach $FM_DATA_DIR and log in over Tailscale SSH"
}

main() {
  if [ "$#" -eq 0 ]; then
    usage
    return 1
  fi
  case "$1" in
    -h|--help) usage; return 0 ;;
  esac

  # After --help, so the usage text is readable from any machine.
  fm_require_linux

  if ! getent group "$FM_GROUP" >/dev/null 2>&1; then
    fm_err "group $FM_GROUP does not exist — run ./install.sh --only users first"
    return 1
  fi

  local user
  for user in "$@"; do
    add_one "$user"
  done
}

main "$@"
