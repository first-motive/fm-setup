#!/usr/bin/env bash
# cut-release.sh — cut this repo's release tag, the one verb `fm release --cut`
# delegates to.
#
#   ./scripts/dev/cut-release.sh              # print the plan, change nothing
#   ./scripts/dev/cut-release.sh --apply      # create and push the tag
#   ./scripts/dev/cut-release.sh --set v0.2.0 # prepare the bump commit for a PR
#
# This repo's release is two things, not one: a version written into the files a
# human pastes from (install.sh's FM_TAG and the curl one-liners it generates),
# and a git tag a rig resolves at flash time. release-tag.sh owns the first and
# only the first — which is why `fm release --repo fm-setup --cut` used to gate
# correctly, delegate, and leave no tag behind (fm-tools#23). This owns the
# second, and reads the first rather than repeating it.
#
# The two halves land in that order and by different routes. The bump is a normal
# change: it edits tracked files, so it goes through a pull request like any
# other, and pushing it straight to main would trip the direct-push tripwire. The
# tag is cut afterwards, onto the merged commit — which is why --apply tags
# origin/main's tip rather than local HEAD, and refuses when the tip does not
# already carry the version it is about to tag.
set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$_here/../.." && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$FM_ROOT/lib.sh"
cd "$FM_ROOT"

usage() {
  cat <<'USAGE'
cut-release.sh — cut this repo's release tag

Prints a plan by default and changes nothing; --apply creates and pushes the tag.
The version is not chosen here: it is read from FM_TAG on the remote's main, so
the tag and the curl one-liners a human pastes can never name different releases.

Usage: ./scripts/dev/cut-release.sh [options]

Options:
  --apply       create and push the tag for the version main already carries
  --set VERSION rewrite FM_TAG and its documented copies, then commit the bump
                on the current branch — open a pull request with it, and cut the
                tag with --apply once it has merged
  -h, --help    show this help
USAGE
}

# FM_TAG as the remote's main carries it. Read from the remote rather than the
# working tree: a maintainer's checkout may sit on a branch, a detached release
# tag, or an unmerged bump, and none of those are what a rig would clone.
_remote_tag() {
  # shellcheck disable=SC2016  # the ${...} here is install.sh's text, not ours
  git show origin/main:install.sh 2>/dev/null \
    | sed -n 's/^FM_TAG="\${FM_TAG:-\(v[0-9][^}"]*\)}"$/\1/p' \
    | head -1
}

# Prepare the bump commit. Deliberately does not push or tag: this edits tracked
# files, so it belongs in a pull request, and the tag belongs on the commit that
# merges.
_set_version() {  # version
  local version="$1" branch
  case "$version" in
    v[0-9]*) ;;
    *) fm_err "version must look like v0.2.0, got '$version'"; return 1 ;;
  esac
  branch="$(git rev-parse --abbrev-ref HEAD)"
  if [ "$branch" = "main" ]; then
    fm_err "refusing to commit a bump on main — branch first, then open a pull request"
    return 1
  fi
  if [ -n "$(git status --porcelain)" ]; then
    fm_err "the tree has uncommitted changes — commit or stash them first"
    return 1
  fi
  "$_here/release-tag.sh" --set "$version"
  git add -A
  git commit -q -m "chore: bump the release tag to $version"
  fm_ok "bump committed on $branch — open a pull request, then re-run with --apply"
}

main() {
  local apply=0 set_version=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --apply) apply=1; shift ;;
      --set) set_version="${2:-}"; shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) fm_err "unknown argument '$1'"; usage >&2; return 1 ;;
    esac
  done

  if [ -n "$set_version" ]; then
    _set_version "$set_version"
    return $?
  fi

  if ! git fetch -q --tags origin main 2>/dev/null; then
    fm_err "could not fetch origin — check network and org access"
    return 1
  fi

  local version tip tagged
  version="$(_remote_tag)"
  if [ -z "$version" ]; then
    fm_err "could not read FM_TAG from origin/main:install.sh"
    return 1
  fi
  tip="$(git rev-parse origin/main)"

  # Already released. Re-cutting would move a tag rigs may already be sitting on,
  # which is the one thing the release channel must never do.
  if git rev-parse -q --verify "refs/tags/$version" >/dev/null; then
    tagged="$(git rev-parse "$version^{commit}")"
    if [ "$tagged" = "$tip" ]; then
      fm_ok "$version is already the main tip (${tip:0:7}) — nothing to cut"
      return 0
    fi
    fm_err "$version already exists at ${tagged:0:7}, but main is at ${tip:0:7}"
    fm_info "bump FM_TAG with --set and merge that first; a released tag is never moved"
    return 1
  fi

  if [ "$apply" = 0 ]; then
    fm_log "plan: tag $version at main ${tip:0:7}"
    fm_info "re-run with --apply to create and push it"
    return 0
  fi

  fm_log "tagging $version at main ${tip:0:7} ..."
  git tag -a "$version" "$tip" -m "$version"
  git push -q origin "$version"
  # Rigs pick this up on their own: the appliance timer converges the machine
  # layer onto the newest v* tag, so nothing is pushed to a fleet from here.
  fm_ok "$version pushed — rigs converge on the next timer tick"
}

main "$@"
