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

# Resolve a path to its physical location, or echo nothing when it does not
# exist. Used to compare "the expected path" against "this checkout" without
# caring which of the two is reached through a symlink.
resolved() { # path
  [ -e "$1" ] || return 0
  (cd -P "$1" 2>/dev/null && pwd) || true
}

do_check() {
  if [ -d "$WORKSPACE" ]; then
    fm_ok "workspace $WORKSPACE"
  else
    fm_warn "workspace $WORKSPACE does not exist yet"
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

do_install() {
  if [ -d "$WORKSPACE" ]; then
    fm_ok "workspace $WORKSPACE"
  else
    fm_log "creating the workspace at $WORKSPACE"
    mkdir -p "$WORKSPACE"
    fm_ok "workspace $WORKSPACE"
  fi

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
  fm_info "workspace $WORKSPACE left in place — other repos live in it"
}

fm_dispatch "$@"
