#!/usr/bin/env bash
#
# users — the shared `fm` group, the /data layout, and the one admin account.
#
# This step deliberately holds no roster. It establishes the structure people
# are added into; the people themselves arrive at runtime through
# `./run.sh add-user <name>`, because who works on a machine changes far more
# often than how the machine is built.
#
# Exactly one account has sudo: the one that provisioned the machine. Everyone
# else gets the fm group and no ability to change the host — which is the same
# rule the machine's CLAUDE.md states, enforced by permissions rather than by
# asking nicely.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$_here/../../lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$_here/../manifest.sh"

fm_require_linux

group_exists() { getent group "$1" >/dev/null 2>&1; }
in_group()     { id -nG "$1" 2>/dev/null | tr ' ' '\n' | grep -qx "$2"; }

# Echo the admin account: whoever is behind the sudo that started this run.
# FM_ADMIN_USER overrides it for a provisioning run driven from another account.
#
# `id -un` closes the chain rather than $USER, which a login shell sets and an
# unattended caller does not. Under `set -u` an unset $USER aborts this step
# instead of degrading it, and the appliance timer runs this step unattended.
admin_user() { printf '%s\n' "${FM_ADMIN_USER:-${SUDO_USER:-${USER:-$(id -un)}}}"; }

# Say so when the workstation has nobody on it but its administrator.
#
# A rebuild wipes every account, and the accounts are the one thing this repo
# deliberately does not hold: the roster is the group itself. So a reinstalled
# workstation comes back green with a team of one, and nothing says the people
# are gone — which is exactly how they were lost once already. This is the line
# that says it.
#
# Workstation only. A jetson is an appliance reached over the tailnet, and a
# rig with one account is what a rig is supposed to look like.
team_of_one() { # admin
  local role="${FM_ROLE:-$(fm_detect_role)}" others=() u
  [ "$role" = "workstation" ] || return 0

  while IFS= read -r u; do
    [ "$u" = "$1" ] || others+=("$u")
  done < <(fm_group_members "$FM_GROUP")

  if [ "${#others[@]}" -eq 0 ]; then
    # Phrased on membership rather than assuming it: an admin removed from the
    # group leaves it empty, and "holds only fm" would then be untrue.
    if in_group "$1" "$FM_GROUP"; then
      fm_warn "$FM_GROUP holds only $1 — this workstation has no team on it"
    else
      fm_warn "$FM_GROUP is empty — this workstation has no team on it"
    fi
    fm_info "add people with: ./run.sh add-user <name>, then each runs ./run.sh onboard"
  fi
}

do_check() {
  local admin members
  admin="$(admin_user)"

  if group_exists "$FM_GROUP"; then
    members="$(fm_group_members "$FM_GROUP" | tr '\n' ' ')"
    fm_ok "group $FM_GROUP: ${members:-no members}"
    team_of_one "$admin"
  else
    fm_warn "group $FM_GROUP missing"
  fi

  if in_group "$admin" sudo; then
    fm_ok "$admin has sudo (admin)"
  else
    fm_warn "$admin is the admin but is not in the sudo group"
  fi

  # Anyone else with sudo is drift worth seeing: this machine is meant to have
  # one administrator.
  local u others=()
  while IFS= read -r u; do
    if [ "$u" != "$admin" ] && [ "$u" != "root" ]; then
      others+=("$u")
    fi
  done < <(fm_group_members sudo)
  if [ "${#others[@]}" -gt 0 ]; then
    fm_warn "other accounts with sudo: ${others[*]}"
  fi

  if [ -d "$FM_DATA_DIR" ]; then
    fm_ok "$FM_DATA_DIR $(stat -c '%U:%G %a' "$FM_DATA_DIR")"
  else
    fm_warn "$FM_DATA_DIR missing"
  fi
  return 0
}

do_install() {
  local admin sub
  admin="$(admin_user)"

  if group_exists "$FM_GROUP"; then
    fm_ok "group $FM_GROUP exists"
  else
    fm_log "creating group $FM_GROUP"
    sudo groupadd "$FM_GROUP"
  fi

  if in_group "$admin" "$FM_GROUP"; then
    fm_ok "$admin is in $FM_GROUP"
  else
    sudo usermod -aG "$FM_GROUP" "$admin"
    fm_warn "$admin added to $FM_GROUP — log out and back in for it to take effect"
  fi

  in_group "$admin" sudo || fm_warn "$admin is the admin but has no sudo — grant it deliberately with: sudo usermod -aG sudo $admin"

  # 2775: group-writable and setgid, so a file one person writes under /data
  # stays owned by the fm group and usable by the rest of the team. Group write
  # is the point — this is shared working storage, not an archive. What protects
  # the irreplaceable parts of it is the backup to external storage, not the
  # mode bits.
  fm_log "laying out $FM_DATA_DIR"
  sudo install -d -o root -g "$FM_GROUP" -m 2775 "$FM_DATA_DIR"
  for sub in "${FM_DATA_SUBDIRS[@]}"; do
    sudo install -d -o root -g "$FM_GROUP" -m 2775 "$FM_DATA_DIR/$sub"
  done
  fm_ok "$FM_DATA_DIR ready (${FM_DATA_SUBDIRS[*]})"

  fm_info "add the rest of the team with: ./run.sh add-user <name>"
}

do_uninstall() {
  # Removing the group makes /data unreachable for everyone, and removing an
  # account takes its home directory with it. Neither is a script's decision.
  fm_warn "accounts, the $FM_GROUP group, and $FM_DATA_DIR are left in place — removing them destroys data"
  fm_info "remove a departed user deliberately with: sudo deluser --remove-home <user>"
  return 0
}

fm_dispatch "$@"
