#!/usr/bin/env bash
#
# agent-ruleset — put the machine's CLAUDE.md in every home directory.
#
# The rule this machine runs on — no system change outside an fm-setup step — is
# only enforceable if it is where an agent will read it, which is the home
# directory it starts in. /etc/skel covers accounts created later.
#
# Two rules keep a step that writes into other people's directories safe:
#
#   * Each home is written as its owner, never as root. A home directory is
#     writable by the person who lives in it, so they can replace any path in it
#     with a symlink between this step's check and its write. Root following
#     that symlink would write wherever it pointed — /etc/passwd, say. Dropping
#     to the owner means the worst case is a user damaging their own file.
#   * A file without the managed marker on it is somebody's own CLAUDE.md and is
#     left alone, as is anything that is a symlink.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$_here/../.." && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$FM_ROOT/lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$FM_ROOT/scripts/manifest.sh"

fm_require_linux

SOURCE="$FM_ROOT/templates/machine-CLAUDE.md"
MARKER="Managed by fm-setup"

# Echo "owner|path" for every place the ruleset belongs: /etc/skel, so accounts
# created later inherit it, and the home of everyone in the fm group.
#
# Membership of that group is the roster — it is what `add-user` maintains, and
# it stays accurate as people join and leave, which a list in a committed file
# would not.
targets() {
  printf 'root|%s\n' "/etc/skel/CLAUDE.md"
  local u home
  while IFS= read -r u; do
    home="$(getent passwd "$u" 2>/dev/null | cut -d: -f6)"
    if [ -n "$home" ] && [ -d "$home" ]; then
      printf '%s|%s\n' "$u" "$home/CLAUDE.md"
    fi
  done < <(fm_group_members "$FM_GROUP")
}

# managed OWNER FILE — 0 when the file is ours to replace. Absent counts as ours;
# a symlink never does.
managed() {
  local owner="$1" file="$2"
  fm_run_as "$owner" test -L "$file" && return 1
  fm_run_as "$owner" test -e "$file" || return 0
  fm_run_as "$owner" grep -qF "$MARKER" "$file" 2>/dev/null
}

do_check() {
  [ -f "$SOURCE" ] || { fm_warn "template missing: $SOURCE"; return 0; }
  local owner file
  while IFS='|' read -r owner file; do
    if fm_run_as "$owner" test -L "$file"; then
      fm_warn "$file is a symlink — left alone"
    elif ! fm_run_as "$owner" test -e "$file"; then
      fm_warn "$file missing"
    elif ! managed "$owner" "$file"; then
      fm_warn "$file is not managed by fm-setup — left alone"
    elif fm_run_as "$owner" cmp -s "$SOURCE" "$file"; then
      fm_ok "$file current"
    else
      fm_warn "$file is out of date"
    fi
  done < <(targets)
  return 0
}

do_install() {
  [ -f "$SOURCE" ] || { fm_err "template missing: $SOURCE"; return 1; }

  local owner file
  while IFS='|' read -r owner file; do
    if fm_run_as "$owner" test -L "$file"; then
      fm_skip "$file is a symlink — leaving it alone"
      continue
    fi
    if ! managed "$owner" "$file"; then
      fm_skip "$file is not ours — leaving the existing file alone"
      continue
    fi
    if fm_run_as "$owner" cmp -s "$SOURCE" "$file" 2>/dev/null; then
      fm_ok "$file current"
      continue
    fi
    fm_run_as "$owner" install -m 0644 "$SOURCE" "$file"
    fm_ok "$file written"
  done < <(targets)
}

do_uninstall() {
  local owner file
  while IFS='|' read -r owner file; do
    if managed "$owner" "$file" && fm_run_as "$owner" test -e "$file"; then
      fm_run_as "$owner" rm -f "$file"
      fm_ok "$file removed"
    else
      fm_skip "$file not managed by fm-setup"
    fi
  done < <(targets)
}

fm_dispatch "$@"
