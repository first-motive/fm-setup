#!/usr/bin/env bash
#
# data-root — the machine's own data tree, beside the checkouts in its workspace.
#
# One place on the host where episodes land off the rigs and leave as dataset
# releases, laid out the same way on every machine so a path in a manifest, a
# training config, or somebody's notes means the same thing everywhere:
#
#   data/
#   ├── recordings/     raw MCAP episodes off the rigs
#   ├── processed/      manifests and clean RLDS
#   ├── annotations/    labels and annotation run directories
#   ├── releases/       dataset release packs
#   ├── staged/         B2 stage-ins (episodes/, lerobot/)
#   ├── hf/             HF_HOME cache — datasets and weights, evictable
#   └── policies/       per-run training output
#
# The tree is machine-owned. Nothing in it is a repo, nothing in it is synced,
# and nothing here ever writes into it: this step lays out the directories and
# hands them to the group.
#
# Where it lives comes from the identity card and from nothing else — see
# machine_workspace below for why FM_HOME does not reach it.
#
# Runs before the users step creates the fm group, for the same reason
# 12-workspace does: the workspace has to exist before anything is put in it.
# The group is applied when it exists and reported when it does not, so the
# converge run after `users` finishes the job.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$_here/../.." && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$FM_ROOT/lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$FM_ROOT/scripts/manifest.sh"

fm_require_linux

# The machine's workspace, read the way every other step reads it, with the one
# branch that does not belong here taken out.
#
# fm_machine_workspace answers "where do checkouts go", and lets FM_HOME outrank
# the card so a person's own tree is their own. That is right for a checkout and
# wrong for this tree: a machine has one data root that the whole team and every
# service share, and reading FM_HOME would put a second, private copy of it in
# whichever home happened to be provisioning, splitting the recordings across two
# paths that both look correct. Clearing FM_HOME for the call keeps the card
# reading, the jq guard, and the default, and drops only that.
machine_workspace() { FM_HOME='' fm_machine_workspace; }

DATA_ROOT="$(machine_workspace)/$FM_DATA_ROOT_NAME"

# The card is validated when it is written, not when it is read, and this step
# is the first to take a path from it straight into mkdir, chgrp and chmod. A
# relative path would build the tree wherever the step happened to be invoked
# from, and a `..` segment would walk it out of the workspace entirely — so both
# are refused here rather than converged into the wrong place quietly.
case "$DATA_ROOT" in
  /*) ;;
  *) fm_warn "workspace '$(machine_workspace)' is not an absolute path"; exit 1 ;;
esac
case "/$DATA_ROOT/" in
  */../*) fm_warn "workspace '$(machine_workspace)' contains a '..' segment"; exit 1 ;;
esac

# Mode 3775 on the root and on every directory under it, the same three reasons
# 12-workspace states for the workspace itself: group write, so the team shares
# one tree; setgid, so an episode written by one person stays readable to the
# next; sticky, so removing an entry needs ownership of it rather than write on
# the directory it sits in. Recordings are the one thing here nobody can re-make.
DATA_MODE=3775

group_exists() { getent group "$FM_GROUP" >/dev/null 2>&1; }

# Echo the root and every directory under it, parents first, so a single loop
# creates a nested entry after the directory that holds it.
data_dirs() {
  local sub
  printf '%s\n' "$DATA_ROOT"
  for sub in "${FM_DATA_ROOT_SUBDIRS[@]}"; do
    printf '%s/%s\n' "$DATA_ROOT" "$sub"
  done
}

# Create DIR, then bring its group and mode to what this step wants.
#
# Each half is applied only when it is not already right, which is what makes a
# re-run by somebody who does not own the directory converge instead of failing:
# a member can create an entry in a group-writable tree but cannot chgrp or
# chmod one another member made — and does not need to, because it is already
# what this step would set it to.
ensure_data_dir() { # dir
  local dir="$1"
  fm_ensure_dir "$dir" || { fm_warn "could not create $dir"; return 1; }

  if group_exists && [ "$(stat -c '%G' "$dir")" != "$FM_GROUP" ] \
     && ! chgrp "$FM_GROUP" "$dir" 2>/dev/null; then
    fm_warn "$dir is group $(stat -c '%G' "$dir"), not $FM_GROUP"
  fi
  if [ "$(stat -c '%a' "$dir")" != "$DATA_MODE" ] \
     && ! chmod "$DATA_MODE" "$dir" 2>/dev/null; then
    fm_warn "$dir is mode $(stat -c '%a' "$dir"), not $DATA_MODE"
  fi
}

# 0 when DIR carries the mode and the group this step sets. The group half is
# skipped on a host that has no fm group yet, where every directory is right
# apart from something no step before `users` can fix.
dir_is_ready() { # dir
  [ "$(stat -c '%a' "$1")" = "$DATA_MODE" ] || return 1
  group_exists || return 0
  [ "$(stat -c '%G' "$1")" = "$FM_GROUP" ]
}

do_check() {
  local dir

  if [ ! -d "$DATA_ROOT" ]; then
    fm_warn "$DATA_ROOT does not exist yet"
    return 0
  fi
  group_exists || fm_warn "group $FM_GROUP does not exist — $DATA_ROOT is not the team's yet"

  while IFS= read -r dir; do
    if [ ! -d "$dir" ]; then
      fm_warn "$dir missing"
    elif dir_is_ready "$dir"; then
      fm_ok "$dir ($(stat -c '%A %U:%G' "$dir"))"
    else
      fm_warn "$dir is $(stat -c '%A %U:%G' "$dir"), wanted mode $DATA_MODE and group $FM_GROUP"
    fi
  done < <(data_dirs)
  return 0
}

do_install() {
  local dir
  group_exists || fm_info "group $FM_GROUP does not exist yet — re-run this step after 'users' to hand $DATA_ROOT to the team"

  fm_log "laying out $DATA_ROOT"
  while IFS= read -r dir; do
    ensure_data_dir "$dir"
  done < <(data_dirs)
  fm_ok "$DATA_ROOT ready (${FM_DATA_ROOT_SUBDIRS[*]})"
}

do_uninstall() {
  # Recordings and releases are the machine's irreplaceables, and an empty
  # directory costs nothing to leave. Neither half of that is a script's call.
  fm_warn "$DATA_ROOT is left in place — removing it destroys recordings and releases"
  fm_info "back it up first with: ./run.sh backup <destination>"
  return 0
}

fm_dispatch "$@"
