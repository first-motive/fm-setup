#!/usr/bin/env bash
#
# test-robot-sudo.sh — prove the robot-sudo verb before it widens sudo anywhere.
#
#   ./scripts/dev/test-robot-sudo.sh
#
# A malformed file in /etc/sudoers.d breaks sudo for every account on the host,
# including the one that would have to repair it — and this verb generates one
# on a robot the vendor still supports. So the rule it writes is parsed by
# `visudo -c` here, in CI, rather than discovered on the workcell.
#
# Every case runs `--dry-run` or a declined write, so nothing here touches
# /etc/sudoers.d and no case needs root.
#
# No test framework, for the same reason the rest of this repo has none: it
# would have to be installed on every machine that provisions.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$_here/../.." && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$FM_ROOT/lib.sh"

VERB="$FM_ROOT/scripts/run/robot-sudo.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  ✗ %s\n' "$1" >&2; }
check() { if [ "$1" = "0" ]; then ok "$2"; else bad "$2"; fi; }

contains() {
  case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac
}

# The account every case grants to: this one, which certainly exists.
USER_NAME="$(id -un)"

# The path the rule is written against. Pinned rather than resolved, so the
# assertions below read the same on a CI container with no systemd as on a
# robot that has one.
export FM_SYSTEMCTL="/usr/bin/systemctl"

printf '\n── robot-sudo ──\n'

# --- the generated rule ------------------------------------------------------

# stdout only: a dry run prints the rule there and its logging on stderr,
# which is what lets the visudo case below feed it straight to sudo.
RULE="$(bash "$VERB" --dry-run --user "$USER_NAME" 2>/dev/null || true)"

contains "$RULE" "/usr/bin/systemctl"
check $? "commands are matched by absolute path, which is the only form sudo matches"

contains "$RULE" "$USER_NAME ALL=(root) NOPASSWD:"
check $? "the rule grants root to the named account only"

for unit in fm-robot-agent fm-zenoh-bridge; do
  contains "$RULE" "restart $unit"
  check $? "restart $unit is allowed"
done

for verb in start stop restart status is-active; do
  contains "$RULE" "systemctl $verb fm-robot-agent"
  check $? "$verb is allowed on the agent"
done

# The grant must not widen on its own. A glob would pick up whatever unit
# somebody names fm-something next, which is a grant nobody reviewed.
if contains "$RULE" "fm-*" || contains "$RULE" "NOPASSWD:ALL" || contains "$RULE" "(ALL)"; then
  bad "the rule stays narrow: no globs, no ALL"
else
  ok "the rule stays narrow: no globs, no ALL"
fi

# daemon-reload re-reads the vendor's unit files too, and no deploy needs it.
if contains "$RULE" "daemon-reload"; then
  bad "daemon-reload is not granted"
else
  ok "daemon-reload is not granted"
fi

# --- sudo itself agrees it parses -------------------------------------------

if command -v visudo >/dev/null 2>&1; then
  printf '%s\n' "$RULE" >"$TMP/rule"
  # visudo -c on a file, not the live one: this validates the syntax and never
  # reads or writes /etc/sudoers.
  if visudo -c -f "$TMP/rule" >/dev/null 2>&1; then
    ok "the generated rule parses under visudo"
  else
    bad "the generated rule parses under visudo"
  fi
else
  printf '  ↷ visudo not installed (skip)\n'
fi

# --- what it refuses ---------------------------------------------------------

if bash "$VERB" --dry-run --user "root; rm -rf /" >/dev/null 2>&1; then
  bad "a username carrying a shell command is refused"
else
  ok "a username carrying a shell command is refused"
fi

if bash "$VERB" --dry-run --user fm-nobody-here >/dev/null 2>&1; then
  bad "an account that does not exist is refused"
else
  ok "an account that does not exist is refused"
fi

if bash "$VERB" --nonsense >/dev/null 2>&1; then
  bad "an unknown flag is refused"
else
  ok "an unknown flag is refused"
fi

# --- a dry run changes nothing ----------------------------------------------

if [ -e /etc/sudoers.d/fm-robot-services ]; then
  bad "a dry run writes no sudoers file"
else
  ok "a dry run writes no sudoers file"
fi

# --- an unattended run declines rather than granting ------------------------

DECLINED="$(NONINTERACTIVE=1 bash "$VERB" --user "$USER_NAME" 2>&1 || true)"
contains "$DECLINED" "declined"
check $? "an unattended run declines the grant"

if [ -e /etc/sudoers.d/fm-robot-services ]; then
  bad "a declined run writes no sudoers file"
else
  ok "a declined run writes no sudoers file"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
