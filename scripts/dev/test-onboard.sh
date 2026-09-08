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
# HOME is overridden as well as the card, because the library's fallback is
# $HOME/fm. Left at the real one, an account that already has ~/fm resolves to
# it and the fixture proves nothing about the fallback — this suite failed on
# fm-ws-01 for exactly that reason, on a resolution that was working.
got="$(FM_MACHINE_FILE="$WORK/absent.json" FM_HOME='' HOME="$WORK/home/sam" resolve_workspace "$WORK/home/sam")"
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

echo "== a non-interactive shell inherits the profile =="
# The failure this covers: ~/.bashrc returns for a shell with no prompt, so a
# source line appended below that guard runs for a terminal and for nothing
# else. `ssh host command`, CI and an agent all landed there with no
# ~/.local/bin (no uv) and no FM_HOME, and `fm doctor` answered about a
# different workspace than the same command typed at a prompt.
#
# Sourcing ~/.bashrc from a non-interactive bash is the guard's own condition,
# which is what makes this a test of the real thing rather than of a mock.
# shellcheck disable=SC2016  # the literals the shell files carry; they must not expand
SHELL_ENV_LINE='. "$HOME/.fm-profile"'
# shellcheck disable=SC2016
BASHRC_LINE='[ -f "$HOME/.fm-profile" ] && . "$HOME/.fm-profile"'

FAKE_HOME="$WORK/home/nia"
mkdir -p "$FAKE_HOME"
printf 'export FM_HOME=%s/fm\n' "$FAKE_HOME" > "$FAKE_HOME/.fm-profile"
stock_bashrc() {
  cat > "$FAKE_HOME/.bashrc" <<'RC'
# ~/.bashrc: executed by bash(1) for non-login shells.
case $- in
    *i*) ;;
      *) return;;
esac
RC
}
# FM_HOME is cleared, not just HOME: the account running this suite is an
# onboarded one, so it exports FM_HOME already, and a child that inherits it
# reports the parent's value as though the fixture had set it.
inherited() { HOME="$FAKE_HOME" FM_HOME='' bash -c '. "$HOME/.bashrc"; printf %s "${FM_HOME:-}"'; }

# The shape this change replaced, kept as the control: a test that cannot fail
# proves nothing about the one that passes.
stock_bashrc
fm_ensure_line "$FAKE_HOME/.bashrc" "$SHELL_ENV_LINE"
if [ -z "$(inherited)" ]; then
  pass "appended below the guard, a non-interactive shell inherits nothing"
else
  fail "the guard did not fire — this fixture is not a stock bashrc"
fi

stock_bashrc
fm_ensure_first_line "$FAKE_HOME/.bashrc" "$BASHRC_LINE"
if [ "$(inherited)" = "$FAKE_HOME/fm" ]; then
  pass "above the guard, a non-interactive shell inherits FM_HOME"
else
  fail "a non-interactive shell inherited '$(inherited)', not $FAKE_HOME/fm"
fi

echo "== the shell wiring converges =="
# A second onboarding run finds its own line and adds nothing; an account
# carrying the old bottom copy ends with one line, not two.
fm_ensure_first_line "$FAKE_HOME/.bashrc" "$BASHRC_LINE"
fm_strip_line "$FAKE_HOME/.bashrc" "$SHELL_ENV_LINE"
fm_ensure_first_line "$FAKE_HOME/.bashrc" "$BASHRC_LINE"
count="$(grep -cxF "$BASHRC_LINE" "$FAKE_HOME/.bashrc")"
if [ "$count" = "1" ] && [ "$(head -n 1 "$FAKE_HOME/.bashrc")" = "$BASHRC_LINE" ]; then
  pass "re-running leaves one source line, still first"
else
  fail "found $count source line(s), first line is: $(head -n 1 "$FAKE_HOME/.bashrc")"
fi

echo "== a missing profile does not break every shell =="
# ~/.bashrc now runs for every bash on the account, so an absent ~/.fm-profile
# must be silence rather than an error on each one.
rm -f "$FAKE_HOME/.fm-profile"
if err="$(HOME="$FAKE_HOME" bash -c '. "$HOME/.bashrc"' 2>&1)" || [ -z "$err" ]; then
  pass "no ~/.fm-profile is quiet"
else
  fail "a missing ~/.fm-profile printed: $err"
fi

echo "== onboard.sh wires the shell and the checkouts the way this suite says =="
# shellcheck disable=SC2016  # the literal is the point; it must not expand
for marker in 'fm_ensure_first_line "$BASHRC" "$BASHRC_LINE"' 'trust_shared_checkouts' 'safe.directory'; do
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
