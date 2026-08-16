#!/usr/bin/env bash
#
# release-tag.sh — read, check, and bump the one release tag this repo has.
#
#   scripts/dev/release-tag.sh              print the tag
#   scripts/dev/release-tag.sh --check      fail if any documented copy drifted
#   scripts/dev/release-tag.sh --set v0.2.0 bump the tag everywhere it appears
#
# The tag lives in install.sh's FM_TAG assignment and nowhere else that a
# machine reads: run.sh no longer carries one, and the flash seed's URL is
# assembled from it at flash time. What remains are the copies a *human* reads —
# the curl one-liners in install.sh's header and in the README — which cannot
# derive anything at runtime because they are text somebody pastes into a shell
# on a machine that has no checkout yet.
#
# So those copies are generated from the assignment by --set and verified
# against it by --check, which CI runs on every pull request. A release bump is
# one command, and a README advertising a tag the installer no longer defaults
# to fails the PR rather than sending the next person to a stale release.
#
# The rewrite is deliberately blunt: every version-shaped token in the two files
# becomes the new tag. That is safe precisely because this repo pins everything
# else — driver, container toolkit, apt source, uv, fm-tools — in
# scripts/manifest.sh, which this script never touches. A version-shaped string
# appearing in install.sh or README.md is therefore this repo's own release by
# construction, and --check enforces that invariant rather than assuming it.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$_here/../.." && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$FM_ROOT/lib.sh"

# The files carrying human-readable copies of the tag. install.sh is both the
# source (its FM_TAG assignment) and a consumer (its header examples).
TAGGED_FILES=(install.sh README.md)

# Anything shaped like a release: a leading v, then digits and dots. Loose on
# purpose — a copy written as v0.1 or v0.1.8.1 must still be caught, because the
# failure being prevented is a stale tag, not a malformed one.
TAG_PATTERN='v[0-9][0-9.]*'

usage() {
  cat <<'EOF'
release-tag.sh — read, check, and bump this repo's release tag

Usage: scripts/dev/release-tag.sh [--check | --set vX.Y.Z]

  (no args)     print the tag install.sh pins
  --check       verify every documented copy matches it; exit 1 on drift
  --set vX.Y.Z  rewrite the assignment and every documented copy
EOF
}

# Echo every version-shaped token in a file that is not the tag itself.
drift_in() { # file tag
  grep -o "$TAG_PATTERN" "$1" | grep -vx "$2" || true
}

do_check() {
  local tag file bad problems=0
  tag="$(fm_release_tag "$FM_ROOT")" || return 1
  for file in "${TAGGED_FILES[@]}"; do
    bad="$(drift_in "$FM_ROOT/$file" "$tag")"
    if [ -n "$bad" ]; then
      fm_err "$file names $(printf '%s' "$bad" | sort -u | tr '\n' ' ')— install.sh pins $tag"
      problems=$((problems + 1))
    else
      fm_ok "$file: $tag"
    fi
  done
  [ "$problems" -eq 0 ] || {
    fm_info "bump with: scripts/dev/release-tag.sh --set $tag"
    return 1
  }
  fm_ok "the release tag is single-sourced"
}

do_set() { # new-tag
  local new="$1" file tmp
  case "$new" in
    v[0-9]*) ;;
    *) fm_err "not a release tag: '$new' (expected vX.Y.Z)"; return 1 ;;
  esac
  for file in "${TAGGED_FILES[@]}"; do
    tmp="$(mktemp)"
    # Written through a temp file rather than `sed -i`, whose in-place flag
    # takes a mandatory suffix argument on BSD sed and none on GNU sed. This
    # script is run from a developer's macOS laptop as often as from CI.
    sed "s/$TAG_PATTERN/$new/g" "$FM_ROOT/$file" >"$tmp"
    if cmp -s "$tmp" "$FM_ROOT/$file"; then
      fm_skip "$file already at $new"
      rm -f "$tmp"
    else
      cat "$tmp" >"$FM_ROOT/$file"
      rm -f "$tmp"
      fm_ok "$file -> $new"
    fi
  done
  fm_info "commit this, then cut the tag: git tag $new && git push origin $new"
}

main() {
  case "${1:-}" in
    "")        fm_release_tag "$FM_ROOT" ;;
    --check)   do_check ;;
    --set)     [ -n "${2:-}" ] || { fm_err "--set needs a tag"; usage >&2; return 1; }
               do_set "$2" ;;
    -h|--help) usage ;;
    *)         fm_err "unknown option: $1"; usage >&2; return 1 ;;
  esac
}

main "$@"
