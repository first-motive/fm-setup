#!/usr/bin/env bash
#
# workspace — the one directory every First Motive checkout lives under, with
# this repo reachable inside it.
#
# The machine's identity card names the workspace; this step makes it real and
# puts fm-setup where the rest of the toolchain expects to find it. That is not
# tidiness. fm-tools resolves every repo it knows about as
# <workspace>/<local_dir> and reports anything missing there as "not cloned", so
# a checkout kept outside the workspace makes `fm doctor` red on a healthy,
# fully provisioned host — and a doctor that is red for a reason nobody can fix
# is a doctor everybody stops reading.
#
# The checkout is aliased, not moved. This step runs from inside the very
# directory it is reasoning about, and moving a tree out from under the script
# executing from it is the kind of failure that leaves a half-provisioned
# machine. install.sh's bootstrap does move a pre-workspace checkout, because it
# runs from the piped copy with nothing executing inside the directory; here a
# symlink buys the same result with none of the risk.
#
# The workspace is the machine's, not a person's, which is why the default sits
# at /opt/fm rather than inside the administrator's home. A home directory is
# mode 700 on Ubuntu, so a workspace inside one is readable by exactly one
# account — and the card names it for the whole host. Group ownership and the
# setgid bit are what make it shared: everyone in the fm group can write, and
# what they create stays group-writable for the next person.
#
# A person's own workspace is still their own. FM_HOME outranks the card, and
# `fm setup-onboard` sets it. Nothing here touches anybody's home.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$_here/../.." && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$FM_ROOT/lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$FM_ROOT/scripts/manifest.sh"

fm_require_linux

WORKSPACE="$(fm_machine_workspace)"
EXPECTED="$(fm_setup_dir)"
LEGACY_WORKSPACE="$FM_MACHINE_WORKSPACE_LEGACY"

# Mode 2775: group-writable, and setgid so a file created by one member stays
# owned by the group the next member is also in. Without the setgid bit a
# checkout cloned by one person is unwritable by everybody else, which is the
# shared workspace failing at the first `git pull` somebody else runs.
WORKSPACE_MODE=2775

# Resolve a path to its physical location, or echo nothing when it does not
# exist. Used to compare "the expected path" against "this checkout" without
# caring which of the two is reached through a symlink.
resolved() { # path
  [ -e "$1" ] || return 0
  (cd -P "$1" 2>/dev/null && pwd) || true
}

do_check() {
  if [ -d "$WORKSPACE" ]; then
    fm_ok "workspace $WORKSPACE ($(stat -c '%A %U:%G' "$WORKSPACE"))"
    # A workspace nobody but its owner can enter is the failure this step
    # exists to prevent, and it is invisible from the owner's own shell.
    case "$WORKSPACE" in
      "$HOME"/*) fm_warn "$WORKSPACE is inside a home directory — the rest of the team cannot read it" ;;
    esac
  else
    fm_warn "workspace $WORKSPACE does not exist yet"
  fi

  if [ -L "$LEGACY_WORKSPACE" ]; then
    fm_ok "$LEGACY_WORKSPACE is a symlink to $(resolved "$LEGACY_WORKSPACE")"
  elif [ -d "$LEGACY_WORKSPACE" ] && [ "$LEGACY_WORKSPACE" != "$WORKSPACE" ]; then
    fm_warn "$LEGACY_WORKSPACE is a real directory, not an alias for $WORKSPACE"
  fi

  local target
  target="$(resolved "$EXPECTED")"
  if [ -z "$target" ]; then
    fm_warn "$EXPECTED missing — the fm CLI will report fm-setup as not cloned"
  elif [ "$target" = "$FM_ROOT" ]; then
    fm_ok "$EXPECTED resolves to this checkout"
  else
    fm_warn "$EXPECTED is a different checkout ($target), not this one ($FM_ROOT)"
  fi

  # Worth reporting on its own: a leftover directory at the old location is a
  # second copy of this repo that someone will eventually edit instead of this
  # one, and it is not obvious from inside either which is live.
  local legacy="$FM_SETUP_LEGACY_DIR"
  if [ -L "$legacy" ]; then
    fm_ok "$legacy is a symlink into the workspace"
  elif [ -d "$legacy" ]; then
    fm_warn "$legacy is a second checkout outside the workspace"
  fi
  return 0
}

# Create the workspace and make it the team's.
#
# Owned by the administrator so provisioning writes into it without sudo, group
# fm so everyone else can too. The group is applied only when it exists: the
# Jetson is a single-purpose appliance and never runs the users step, so a hard
# requirement here would fail the rig on a group it has no reason to have.
ensure_workspace_dir() {
  if [ -d "$WORKSPACE" ]; then
    fm_ok "workspace $WORKSPACE"
  else
    fm_log "creating the workspace at $WORKSPACE"
    fm_ensure_dir "$WORKSPACE"
    fm_ok "workspace $WORKSPACE"
  fi

  # The group is the whole point of the move, so a failure to apply it is said
  # out loud rather than swallowed: a workspace the team cannot write to looks
  # identical to one it can until somebody's first clone fails.
  if ! getent group "$FM_GROUP" >/dev/null 2>&1; then
    fm_info "group $FM_GROUP does not exist — leaving $WORKSPACE ungrouped"
  elif chgrp "$FM_GROUP" "$WORKSPACE" && chmod "$WORKSPACE_MODE" "$WORKSPACE"; then
    fm_ok "$WORKSPACE is group $FM_GROUP, mode $WORKSPACE_MODE"
  else
    fm_warn "could not set $WORKSPACE to group $FM_GROUP, mode $WORKSPACE_MODE"
    fm_info "the team cannot write there until it is: sudo chgrp $FM_GROUP $WORKSPACE && sudo chmod $WORKSPACE_MODE $WORKSPACE"
  fi
}

# Leave the old path answering.
#
# The machine's workspace used to be ~/fm, and that path is written into shell
# files, notes, and half the README of every repo that was cloned before the
# move. A symlink costs nothing and keeps all of them working.
#
# Never created over a real directory. The tree there holds somebody's
# checkouts, this step cannot tell whether they carry work, and replacing it
# with a link would take them out of reach.
ensure_legacy_alias() {
  [ "$LEGACY_WORKSPACE" != "$WORKSPACE" ] || return 0

  if [ -L "$LEGACY_WORKSPACE" ]; then
    fm_ok "$LEGACY_WORKSPACE -> $(resolved "$LEGACY_WORKSPACE")"
  elif [ -e "$LEGACY_WORKSPACE" ]; then
    fm_warn "$LEGACY_WORKSPACE is a real directory — leaving it"
    fm_info "the machine's workspace is $WORKSPACE now; move what is still wanted, then remove it"
  else
    ln -s "$WORKSPACE" "$LEGACY_WORKSPACE"
    fm_ok "linked $LEGACY_WORKSPACE -> $WORKSPACE"
  fi
}

do_install() {
  ensure_workspace_dir
  ensure_legacy_alias

  local target
  target="$(resolved "$EXPECTED")"
  if [ "$target" = "$FM_ROOT" ]; then
    fm_ok "$EXPECTED resolves to this checkout"
  elif [ -n "$target" ]; then
    # Two checkouts of one repo on one machine is a situation to report, never
    # to resolve by deleting: the other one may be the one carrying work, and
    # this step cannot tell.
    fm_warn "$EXPECTED already points at another checkout ($target) — leaving it"
    fm_info "the fm CLI reads that one; remove or move it if this checkout ($FM_ROOT) is the live one"
  elif [ -e "$EXPECTED" ]; then
    fm_warn "$EXPECTED exists but is not a directory — leaving it"
  else
    ln -s "$FM_ROOT" "$EXPECTED"
    fm_ok "linked $EXPECTED -> $FM_ROOT"
  fi
}

do_uninstall() {
  # Only the link this step could have made is removed, and only after checking
  # it still points where this step pointed it. The workspace itself stays: every
  # other First Motive repo lives in it, and none of them are this step's to
  # delete.
  if [ -L "$EXPECTED" ] && [ "$(resolved "$EXPECTED")" = "$FM_ROOT" ]; then
    rm -f "$EXPECTED"
    fm_ok "removed the link at $EXPECTED"
  elif [ -e "$EXPECTED" ]; then
    fm_skip "$EXPECTED is a real checkout, not this step's link"
  else
    fm_skip "$EXPECTED not present"
  fi

  if [ -L "$LEGACY_WORKSPACE" ] && [ "$(resolved "$LEGACY_WORKSPACE")" = "$(resolved "$WORKSPACE")" ]; then
    rm -f "$LEGACY_WORKSPACE"
    fm_ok "removed the alias at $LEGACY_WORKSPACE"
  fi
  fm_info "workspace $WORKSPACE left in place — other repos live in it"
}

fm_dispatch "$@"
