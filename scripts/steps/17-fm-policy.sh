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
    # A checkout is not a working policy layer. Without the project's own venv
    # there is no `fm policy` to run, which is the whole reason this role has it.
    if [ -d "$POLICY_DIR/.venv" ]; then
      fm_ok "$POLICY_DIR/.venv resolved"
    else
      fm_warn "$POLICY_DIR has no .venv — 'fm policy' will not run until it is installed"
    fi
  elif [ -e "$POLICY_DIR" ]; then
    fm_warn "$POLICY_DIR exists but is not a git checkout"
  else
    fm_warn "$POLICY_DIR missing — this host has nothing to train or serve with"
  fi
  return 0
}

# uv lands in ~/.local/bin, which reaches PATH only after `uv tool update-shell`
# and a new shell. Neither has happened during provisioning, and a non-login ssh
# does not source a profile either — so look there directly, as 15-fm-cli does.
uv_bin() {  # home
  local home="$1"
  if fm_has_cmd uv; then command -v uv; return 0; fi
  [ -x "$home/.local/bin/uv" ] && printf '%s\n' "$home/.local/bin/uv" && return 0
  return 1
}

# Resolve the project's venv, so the checkout is a policy layer rather than a
# directory. Idempotent: `uv sync` is a no-op once the lockfile is satisfied.
#
# A warning, never a failure, for the same reason the clone is: a host that
# cannot reach the network still has a working GPU and the rest of its role.
ensure_installed() {  # owner  home
  local owner="$1" home="$2" uv
  [ -x "$POLICY_DIR/install.sh" ] || {
    fm_warn "$POLICY_DIR has no install.sh — leaving the checkout as it is"
    return 0
  }
  if ! uv="$(uv_bin "$home")"; then
    fm_warn "uv is not installed for $owner — cannot resolve $POLICY_DIR/.venv"
    fm_info "the fm-cli step installs it; re-run: ./install.sh --${FM_ROLE:-workstation} --only fm-cli,fm-policy"
    return 0
  fi
  fm_log "resolving $POLICY_DIR/.venv (as $owner) ..."
  if as_workspace_owner env PATH="$(dirname "$uv"):$PATH" "$POLICY_DIR/install.sh" >/dev/null 2>&1; then
    fm_ok "$POLICY_DIR/.venv resolved"
  else
    fm_warn "could not resolve $POLICY_DIR/.venv — the rest of this role is unaffected"
    fm_info "run it directly to see why: $POLICY_DIR/install.sh"
  fi
}

# Who the checkout belongs to: the workspace's own owner, falling back to the
# account that invoked sudo, then to whoever is running.
#
# It is not root, and that is the point. install.sh runs under sudo, so a clone
# left as-is runs as root — which owns no GitHub credential, and would leave a
# root-owned tree inside a group-writable workspace for a repo whose whole
# premise is that it is somebody's working tree.
workspace_owner() {
  local workspace
  workspace="$(fm_machine_workspace)"
  if [ -d "$workspace" ]; then
    stat -c '%U' "$workspace" 2>/dev/null && return 0
  fi
  printf '%s\n' "${SUDO_USER:-${USER:-$(id -un)}}"
}

# as_workspace_owner CMD… — run a command as that account, or plainly when it is
# already the one running. Mirrors as_owner in 80-agent-ruleset.sh.
as_workspace_owner() {
  local owner
  owner="$(workspace_owner)"
  if [ "$owner" = "$(id -un)" ]; then
    "$@"
  else
    sudo -u "$owner" "$@"
  fi
}

do_install() {
  local owner home
  owner="$(workspace_owner)"
  home="$(getent passwd "$owner" 2>/dev/null | cut -d: -f6)"
  [ -n "$home" ] || home="$HOME"
  if [ -d "$POLICY_DIR/.git" ]; then
    fm_ok "$POLICY_DIR already cloned"
    fm_info "bring it forward deliberately with: git -C $POLICY_DIR pull"
    # Still resolve the venv. The checkout is left where it is, but a converge
    # that finds one without its environment should repair it rather than report
    # a policy layer that cannot run.
    ensure_installed "$owner" "$home"
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

  fm_log "cloning $FM_POLICY_REPO into $POLICY_DIR (as $owner)"
  # GIT_TERMINAL_PROMPT=0 so a host with no credential fails in a second rather
  # than sitting on a username prompt for the rest of an unattended provision.
  if as_workspace_owner env GIT_TERMINAL_PROMPT=0 git clone --quiet "$POLICY_URL" "$POLICY_DIR"; then
    fm_ok "$POLICY_DIR cloned"
    ensure_installed "$owner" "$home"
  else
    fm_warn "could not clone $FM_POLICY_REPO — the rest of this role is unaffected"
    # Named for the role being installed, and for the account the clone runs as.
    # This repo is private, and install.sh runs under sudo, so a credential held
    # by the operator's own login is not the one git sees: the clone is done as
    # the workspace's owner, which is the account that has to be authenticated.
    fm_info "authenticate as $owner (gh auth login), then re-run:"
    fm_info "  ./install.sh --${FM_ROLE:-workstation} --only fm-policy"
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
