#!/usr/bin/env bash
#
# etckeeper — a git history for /etc.
#
# The ledger records what each step added to apt. Nothing records what a step,
# a package's postinst, or a person changed under /etc — and /etc is where the
# differences between two supposedly identical machines actually live. etckeeper
# is the cheapest possible answer: a git repository at /etc/.git, and an apt hook
# that commits before and after every package operation.
#
# It explains nothing on its own. What it gives is a diff to read when a machine
# behaves unlike its twin, and a date to attach to the change.
#
# Early in the order, right after the system update: a history that starts before
# the other steps run is a history of what this repo did to the machine.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$_here/../../lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$_here/../manifest.sh"

fm_require_linux

ETC_GIT=/etc/.git

# Uncommitted paths under /etc, empty when the history is current. Read through
# sudo because /etc/.git is root-owned and git refuses a repository it does not
# trust to a different user.
etc_dirty() { sudo git -C /etc status --porcelain 2>/dev/null; }

do_check() {
  if ! fm_has_pkg etckeeper; then
    fm_warn "etckeeper missing — /etc has no change history"
    return 0
  fi
  fm_ok "etckeeper installed"

  if [ ! -d "$ETC_GIT" ]; then
    fm_warn "$ETC_GIT missing — etckeeper is installed but never initialised"
    return 0
  fi

  local dirty
  dirty="$(etc_dirty)"
  if [ -z "$dirty" ]; then
    fm_ok "/etc committed ($(sudo git -C /etc rev-list --count HEAD 2>/dev/null || echo 0) commits)"
  else
    # Not an error. Somebody changed something and has not said why, which is
    # exactly what this step exists to make visible.
    fm_warn "/etc has uncommitted changes:"
    printf '%s\n' "$dirty" | sed 's/^/        /' >&2
  fi
  return 0
}

do_install() {
  fm_apt_install etckeeper etckeeper

  if [ -d "$ETC_GIT" ]; then
    fm_ok "$ETC_GIT already initialised"
  else
    fm_log "etckeeper init"
    sudo etckeeper init
  fi

  # The first commit, and every later one this step makes. `etckeeper commit`
  # is a no-op on a clean tree, so a re-run adds nothing.
  if [ -n "$(etc_dirty)" ]; then
    sudo etckeeper commit "fm-setup: provisioning run" >/dev/null
    fm_ok "/etc committed"
  else
    fm_ok "/etc already committed"
  fi

  # The apt hooks are what make this automatic rather than a habit. They ship
  # with the package and are on by default; saying so here is how a machine
  # where somebody turned them off gets noticed.
  if [ -f /etc/apt/apt.conf.d/05etckeeper ]; then
    fm_ok "apt commits /etc before and after every package operation"
  else
    fm_warn "the etckeeper apt hook is missing — /etc will only be committed by hand"
  fi
}

do_uninstall() {
  # The package goes; the history stays. A git repository of every change ever
  # made to this machine's configuration is the one thing here that cannot be
  # rebuilt, and an uninstall is not a reason to lose it.
  fm_apt_uninstall etckeeper || fm_warn "etckeeper left in place"
  if [ -d "$ETC_GIT" ]; then
    fm_warn "$ETC_GIT left in place — remove it deliberately if you mean to drop the history"
  fi
}

fm_dispatch "$@"
