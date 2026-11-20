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

printf '\n── robot-sudo ──\n'

# --- the generated rule ------------------------------------------------------

# stdout only: a dry run prints the rule there and its logging on stderr,
# which is what lets the visudo case below feed it straight to sudo.
RULE="$(bash "$VERB" --dry-run --user "$USER_NAME" 2>/dev/null || true)"

# The one line that grants, and nothing else outside comments: a second rule
# here would be a grant this verb never showed the operator.
grants="$(printf '%s\n' "$RULE" | grep -v '^#' | grep -v '^$')"
if [ "$grants" = "$USER_NAME ALL=(ALL) NOPASSWD: ALL" ]; then
  ok "the rule grants the named account passwordless sudo for every command"
else
  bad "the rule grants the named account passwordless sudo for every command (got: $grants)"
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

# The agent calls the writer by path, so the verb still ships it.
contains "$(bash "$VERB" --help)" "/usr/local/sbin/fm-comms-set"
check $? "the fleet-env writer is installed with the grant"


# --- the writer itself -------------------------------------------------------

WRITER="$FM_ROOT/templates/fm-comms-set"
FLEET_ENV="$TMP/fm-comms.env"
printf '# a comment an operator reads\nFM_ROS_DOMAIN_ID=0\nROS_DOMAIN_ID=0\nFM_ROUTER_ENDPOINT=tcp/router:7447\n' >"$FLEET_ENV"

run_writer() { FM_COMMS_ENV="$FLEET_ENV" bash "$WRITER" "$@"; }

if run_writer FM_ROS_DOMAIN_ID 3 >/dev/null 2>&1; then
  ok "the writer sets a domain"
else
  bad "the writer sets a domain"
fi

# The installer keeps both spellings equal — the bridge unit exports one and the
# rendered config reads the other. Setting one alone is the silent defect.
if grep -q '^FM_ROS_DOMAIN_ID=3$' "$FLEET_ENV" && grep -q '^ROS_DOMAIN_ID=3$' "$FLEET_ENV"; then
  ok "one domain write sets both spellings"
else
  bad "one domain write sets both spellings"
fi

if grep -q '^FM_ROUTER_ENDPOINT=tcp/router:7447$' "$FLEET_ENV" \
  && grep -q '^# a comment an operator reads$' "$FLEET_ENV"; then
  ok "every other line survives a write"
else
  bad "every other line survives a write"
fi

if run_writer FM_DDS_IFACE wlp8s0 >/dev/null 2>&1 && grep -q '^FM_DDS_IFACE=wlp8s0$' "$FLEET_ENV"; then
  ok "the writer sets an interface"
else
  bad "the writer sets an interface"
fi

if run_writer FM_ROS_DOMAIN_ID 3 >/dev/null 2>&1 \
  && [ "$(grep -c '^FM_ROS_DOMAIN_ID=' "$FLEET_ENV")" = "1" ]; then
  ok "a repeated write leaves one assignment"
else
  bad "a repeated write leaves one assignment"
fi

# One case per call rather than a list of strings split on whitespace: a value
# that contains a space is the case worth testing, and word splitting turned its
# quotes into literal characters — so `'not an iface'` reached the writer as
# three arguments and was refused for the wrong reason.
refuses() { # key value…
  if run_writer "$@" >/dev/null 2>&1; then
    bad "the writer refuses: $*"
  else
    ok "the writer refuses: $*"
  fi
}

refuses FM_ROS_DOMAIN_ID 999
refuses FM_ROS_DOMAIN_ID three
refuses FM_DDS_IFACE "not an iface"
refuses FM_ROUTER_ENDPOINT tcp/evil:7447
refuses PATH /tmp/evil

if run_writer FM_DDS_IFACE >/dev/null 2>&1; then
  bad "the writer needs both a key and a value"
else
  ok "the writer needs both a key and a value"
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
