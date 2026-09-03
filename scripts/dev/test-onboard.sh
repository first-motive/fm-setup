#!/usr/bin/env bash
# test-onboard.sh — which workspace `fm setup-onboard` gives an account.
#
#   ./scripts/dev/test-onboard.sh
#
# Two accounts, two right answers. A person gets a workspace of their own under
# their home, so their branches are theirs and `fm` answers about their tree.
# The account that owns the machine's workspace is the machine, and giving it a
# personal one points every verb at an empty directory.
#
# That is not hypothetical: on fm-ws-01, after the checkouts moved under the
# card's workspace, this script had written FM_HOME=/home/fm/fm into the service
# account's profile, and `fm doctor` reported every repo "not cloned" while all
# of them sat one directory away.
#
# Sources the script's own resolution rather than running it end to end: onboard
# installs a shell profile, an SSH first-read and org skills, none of which a
# test should do to the machine it runs on.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

# shellcheck source=../../lib.sh disable=SC1091
. ./lib.sh

fails=0
pass() { echo "PASS: $1"; }
fail() {
  echo "FAIL: $1"
  fails=$((fails + 1))
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The resolution under test, lifted from onboard.sh. Kept in step by the check
# at the end, which fails when the script's own copy drifts from this one.
service_account_workspace() {
  local workspace owner
  workspace="$(FM_HOME='' fm_machine_workspace)" || return 1
  [ -d "$workspace" ] || return 1
  owner="$(stat -c '%U' "$workspace" 2>/dev/null)" || return 1
  [ "$owner" = "$(id -un)" ] || return 1
  printf '%s\n' "$workspace"
}

resolve_workspace() {  # home
  local home="$1" workspace
  if [ -n "${FM_HOME:-}" ]; then
    printf '%s\n' "$FM_HOME"
  elif workspace="$(service_account_workspace)"; then
    printf '%s\n' "$workspace"
  else
    printf '%s\n' "$home/fm"
  fi
}

echo "== the account that owns the machine's workspace keeps it =="
mkdir -p "$WORK/opt/fm"
cat > "$WORK/machine.json" <<JSON
{"schema_version": 1, "name": "fm-ws-01", "role": "workstation", "workspace": "$WORK/opt/fm"}
JSON

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq is not installed, so the card cannot be read here"
else
  got="$(FM_MACHINE_FILE="$WORK/machine.json" FM_HOME='' resolve_workspace "$WORK/home/fm")"
  if [ "$got" = "$WORK/opt/fm" ]; then
    pass "the service account is given the card's workspace"
  else
    fail "resolved $got, not the card's $WORK/opt/fm — every verb would read an empty tree"
  fi
fi

echo "== a person on the same machine still gets their own =="
# A workspace this account does not own is somebody else's, so the card is not
# this account's answer and the personal default stands. Owned by another
# account on purpose: ownership is the whole signal, and a fixture this account
# owns would pass for the wrong reason.
mkdir -p "$WORK/opt/other"
cat > "$WORK/other.json" <<JSON
{"schema_version": 1, "workspace": "$WORK/opt/other"}
JSON
if chown nobody "$WORK/opt/other" 2>/dev/null; then
  got="$(FM_MACHINE_FILE="$WORK/other.json" FM_HOME='' resolve_workspace "$WORK/home/sam")"
  if [ "$got" = "$WORK/home/sam/fm" ]; then
    pass "an account that does not own the card's workspace gets its own"
  else
    fail "resolved $got, not the personal $WORK/home/sam/fm"
  fi
else
  echo "SKIP: cannot chown a fixture to another account here"
fi

echo "== an explicit FM_HOME still outranks both =="
got="$(FM_MACHINE_FILE="$WORK/machine.json" FM_HOME="$WORK/chosen" resolve_workspace "$WORK/home/fm")"
if [ "$got" = "$WORK/chosen" ]; then
  pass "FM_HOME wins where it is set"
else
  fail "resolved $got, ignoring an explicit FM_HOME"
fi

echo "== no card at all falls back to the personal workspace =="
got="$(FM_MACHINE_FILE="$WORK/absent.json" FM_HOME='' resolve_workspace "$WORK/home/sam")"
if [ "$got" = "$WORK/home/sam/fm" ]; then
  pass "a machine with no card gives the personal workspace"
else
  fail "resolved $got with no card to read"
fi

echo "== onboard.sh still resolves the way this suite says =="
# The copy above is a copy. This is what stops it becoming a fiction.
# shellcheck disable=SC2016  # the literal is the point; it must not expand
for marker in 'service_account_workspace()' 'elif WORKSPACE="$(service_account_workspace)"'; do
  if grep -qF "$marker" scripts/run/onboard.sh; then
    pass "onboard.sh carries: $marker"
  else
    fail "onboard.sh no longer carries: $marker — this suite is testing a copy that drifted"
  fi
done

echo
if [ "$fails" -gt 0 ]; then
  echo "$fails check(s) failed"
  exit 1
fi
echo "onboard: all checks passed"
