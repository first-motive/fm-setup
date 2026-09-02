#!/usr/bin/env bash
#
# Install the personal SSH first-read files without touching shared host state.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$_here/../.." && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$FM_ROOT/lib.sh"

AGENTS_SOURCE="$FM_ROOT/templates/ssh-first-read-AGENTS.md"
HOOK_SOURCE="$FM_ROOT/templates/ssh-first-read.sh"
AGENTS_TARGET="$HOME/AGENTS.md"
HOOK_TARGET="$HOME/.fm-ssh-first-read"
PROFILE="$HOME/.profile"
MARKER="Managed by fm-setup"
# shellcheck disable=SC2016
HOOK_LINE='. "$HOME/.fm-ssh-first-read"'

ensure_agents() {
  if [ -L "$AGENTS_TARGET" ]; then
    fm_skip "$AGENTS_TARGET is a symlink - leaving it as the personal first-read"
    return 0
  fi
  if [ -e "$AGENTS_TARGET" ] && ! grep -qF "$MARKER" "$AGENTS_TARGET" 2>/dev/null; then
    fm_skip "$AGENTS_TARGET is personal - leaving it as the first-read"
    return 0
  fi
  if cmp -s "$AGENTS_SOURCE" "$AGENTS_TARGET" 2>/dev/null; then
    fm_ok "$AGENTS_TARGET current"
    return 0
  fi
  install -m 0600 "$AGENTS_SOURCE" "$AGENTS_TARGET"
  fm_ok "$AGENTS_TARGET written"
}

ensure_hook() {
  if [ -L "$HOOK_TARGET" ]; then
    fm_warn "$HOOK_TARGET is a symlink - SSH first-read was not enabled"
    return 0
  fi
  if [ -e "$HOOK_TARGET" ] && ! grep -qF "$MARKER" "$HOOK_TARGET" 2>/dev/null; then
    fm_warn "$HOOK_TARGET is not managed by fm-setup - SSH first-read was not enabled"
    return 0
  fi
  if cmp -s "$HOOK_SOURCE" "$HOOK_TARGET" 2>/dev/null; then
    fm_ok "$HOOK_TARGET current"
  else
    install -m 0600 "$HOOK_SOURCE" "$HOOK_TARGET"
    fm_ok "$HOOK_TARGET written"
  fi
  fm_ensure_line "$PROFILE" "$HOOK_LINE"
  fm_ok "SSH first-read sourced from $PROFILE"
}

main() {
  [ -f "$AGENTS_SOURCE" ] || { fm_err "template missing: $AGENTS_SOURCE"; return 1; }
  [ -f "$HOOK_SOURCE" ] || { fm_err "template missing: $HOOK_SOURCE"; return 1; }

  ensure_agents
  ensure_hook
}

main "$@"
