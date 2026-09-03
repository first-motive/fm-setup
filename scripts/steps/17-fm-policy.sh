#!/usr/bin/env bash
#
# fm-policy — the training repo, in the machine's workspace.
#
# A trainer is a GPU host that exists to run fm-policy, so the checkout is part
# of what provisioning means there rather than something the first person to log
# in remembers to do. It lands beside every other First Motive checkout, at
# <workspace>/fm-policy, which is where the fm CLI looks for it.
#
# Cloned, never updated. `git pull` on a training host would move the code under
# a run that is already going, and the repo is somebody's working tree the
# moment they check out a branch on it — bringing it forward is `fm update`,
# typed by a person who knows what is running.
#
# Not pinned, for the same reason fm-ai is not: a policy repo is worked on, and
# a tag here would hold every trainer at the state of the day it was built. What
# provisioning owes the machine is that the repo is present and current at clone
# time; which commit trains a model is the run's business, recorded by the run.
#
# The clone needs a credential the machine may not have — fm-policy is private,
# and a trainer brought up from an image has no GitHub identity yet. That is a
# warning and never a failure: the rest of the role is a working GPU host, and
# the person who authenticates re-runs this step in a second.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$_here/../.." && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$FM_ROOT/lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$FM_ROOT/scripts/manifest.sh"

fm_require_linux

POLICY_DIR="$(fm_machine_workspace)/$FM_POLICY_CHECKOUT_NAME"
POLICY_URL="https://github.com/$FM_POLICY_REPO.git"

do_check() {
  if [ -d "$POLICY_DIR/.git" ]; then
    fm_ok "$POLICY_DIR ($(git -C "$POLICY_DIR" rev-parse --short HEAD 2>/dev/null || echo 'no commit'))"
  elif [ -e "$POLICY_DIR" ]; then
    fm_warn "$POLICY_DIR exists but is not a git checkout"
  else
    fm_warn "$POLICY_DIR missing — this trainer has nothing to train with"
  fi
  return 0
}

do_install() {
  if [ -d "$POLICY_DIR/.git" ]; then
    fm_ok "$POLICY_DIR already cloned"
    fm_info "bring it forward deliberately with: git -C $POLICY_DIR pull"
    return 0
  fi
  if [ -e "$POLICY_DIR" ]; then
    # Something is already at the path, and this step cannot tell whether it
    # holds work. Cloning over it is the one move that cannot be undone.
    fm_warn "$POLICY_DIR exists and is not a checkout — leaving it"
    return 0
  fi

  fm_require_cmd git || return 1
  fm_ensure_dir "$(dirname "$POLICY_DIR")"

  fm_log "cloning $FM_POLICY_REPO into $POLICY_DIR"
  # GIT_TERMINAL_PROMPT=0 so a host with no credential fails in a second rather
  # than sitting on a username prompt for the rest of an unattended provision.
  if GIT_TERMINAL_PROMPT=0 git clone --quiet "$POLICY_URL" "$POLICY_DIR"; then
    fm_ok "$POLICY_DIR cloned"
  else
    fm_warn "could not clone $FM_POLICY_REPO — the rest of this role is unaffected"
    # Named for the role being installed, not for one of them. This step runs on
    # the workstation as well as the trainer, and a hint that says --trainer on a
    # workstation is a command the operator pastes and watches fail.
    fm_info "authenticate, then re-run: ./install.sh --${FM_ROLE:-workstation} --only fm-policy"
  fi
}

do_uninstall() {
  # A checkout is somebody's working tree, and an uncommitted branch on a
  # training host is the copy nothing else has.
  fm_warn "$POLICY_DIR is left in place — it may hold work that is only there"
  fm_info "remove it deliberately with: rm -rf $POLICY_DIR"
  return 0
}

fm_dispatch "$@"
