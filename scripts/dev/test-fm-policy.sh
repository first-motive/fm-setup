#!/usr/bin/env bash
#
# test-fm-policy.sh — exercise the trainer's fm-policy checkout.
#
#   ./scripts/dev/test-fm-policy.sh
#
# The step puts somebody's working tree on a training host, so the cases worth
# a test are the ones about not destroying it: a path that already holds
# something is left alone, a second install does not re-clone over a checkout,
# and uninstall removes nothing. Those are the moves with no undo.
#
# The clone itself is not exercised. It reaches github.com for a private repo,
# and a test that needs a credential is one that fails for a reason unrelated to
# the code. What is asserted instead is that every path around the clone —
# missing, occupied, already cloned — resolves without touching what it found.
#
# Runs against a card and a workspace in a temp directory, so nothing here
# touches /etc/fm, /opt/fm, or the developer's own machine, and no case needs
# root.
#
# No test framework, for the reason test-machine.sh gives: this repo has no test
# runner, and a dependency would have to be installed on every machine that
# provisions.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$_here/../.." && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$FM_ROOT/lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$FM_ROOT/scripts/manifest.sh"

# The step's own fm_require_linux is GNU/Linux. The suite says so rather than
# failing halfway through on a developer's Mac.
[ "$(uname -s)" = "Linux" ] || { fm_warn "fm-policy is a Linux step — skipping on $(uname -s)"; exit 0; }
fm_require_cmd jq
fm_require_cmd git

STEP="$FM_ROOT/scripts/steps/17-fm-policy.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP
export FM_MACHINE_FILE="$TMP/machine.json"
WORKSPACE="$TMP/ws"
CHECKOUT="$WORKSPACE/$FM_POLICY_CHECKOUT_NAME"
mkdir -p "$WORKSPACE"
printf '{"role":"trainer","workspace":"%s"}\n' "$WORKSPACE" > "$FM_MACHINE_FILE"

PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); printf '    %s✓%s %s\n' "${FM_C_GREEN}" "${FM_C_RESET}" "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '    %s✗%s %s\n' "${FM_C_RED}" "${FM_C_RESET}" "$1"; }

# assert_eq LABEL EXPECTED ACTUAL
assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"; printf '        expected: %s\n        actual:   %s\n' "$2" "$3"; fi
}

# assert_rc LABEL EXPECTED_CODE COMMAND… — run COMMAND, compare its exit code.
assert_rc() {
  local label="$1" want="$2" got=0; shift 2
  "$@" >/dev/null 2>&1 || got=$?
  assert_eq "$label" "$want" "$got"
}

step() { bash "$STEP" "$@"; }

# --- Nothing there yet ------------------------------------------------------
#
# A trainer that has not authenticated has no checkout, and check is what tells
# the operator so. It reports and never fails: the rest of the role is a working
# GPU host.

assert_rc "check exits 0 with no checkout" 0 step check
assert_eq "check created nothing" "false" \
  "$([ -e "$CHECKOUT" ] && echo true || echo false)"

# --- A path that already holds something ------------------------------------
#
# Cloning over a directory somebody put there is the one move that cannot be
# undone, so the step leaves it and says why.

mkdir -p "$CHECKOUT"
printf 'a half-finished experiment\n' > "$CHECKOUT/notes.txt"

assert_rc "check exits 0 on a path that is not a checkout" 0 step check
assert_rc "install exits 0 on a path that is not a checkout" 0 step install
assert_eq "install left the existing directory alone" "a half-finished experiment" \
  "$(cat "$CHECKOUT/notes.txt")"

rm -rf "$CHECKOUT"

# --- Already cloned ---------------------------------------------------------
#
# The appliance converge runs this step unattended on every tag. A re-run must
# not move the code under a training run that is already going, so install on an
# existing checkout reports and stops rather than pulling.

git init --quiet "$CHECKOUT"
git -C "$CHECKOUT" -c user.email=test@example.com -c user.name=test \
  commit --quiet --allow-empty -m "init"
head_before="$(git -C "$CHECKOUT" rev-parse HEAD)"
printf 'uncommitted work\n' > "$CHECKOUT/scratch.txt"

assert_rc "check exits 0 on a checkout" 0 step check
assert_rc "install exits 0 on a checkout" 0 step install
assert_eq "install did not move the checkout" "$head_before" \
  "$(git -C "$CHECKOUT" rev-parse HEAD)"
assert_eq "install left uncommitted work in place" "uncommitted work" \
  "$(cat "$CHECKOUT/scratch.txt")"

# --- uninstall keeps the checkout -------------------------------------------
#
# An uncommitted branch on a training host is the copy nothing else has.

assert_rc "uninstall exits 0" 0 step uninstall
assert_eq "uninstall leaves the checkout in place" "true" \
  "$([ -d "$CHECKOUT/.git" ] && echo true || echo false)"
assert_eq "uninstall leaves uncommitted work in place" "uncommitted work" \
  "$(cat "$CHECKOUT/scratch.txt")"

# --- the clone runs as the workspace's owner, never as root ------------------
#
# install.sh runs under sudo, so a clone left as-is runs as root. Root owns no
# GitHub credential, and this repo is private — on fm-ws-01 that failed with
# "could not read Username for 'https://github.com'" while the operator's own
# account was authenticated the whole time. A root-owned checkout would also be
# the wrong thing to leave behind for a repo that is somebody's working tree.

rm -rf "$CHECKOUT"
fake_bin="$TMP/bin"
mkdir -p "$fake_bin"
# Records who the clone would have run as, and refuses to reach the network.
cat > "$fake_bin/git" <<'FAKEGIT'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = "clone" ]; then
    printf '%s\n' "$(id -un)" > "$FM_TEST_CLONE_USER_FILE"
    exit 1
  fi
done
exec /usr/bin/git "$@"
FAKEGIT
chmod +x "$fake_bin/git"

export FM_TEST_CLONE_USER_FILE="$TMP/clone-user"
PATH="$fake_bin:$PATH" step install >/dev/null 2>&1 || true

assert_eq "the clone runs as the workspace's owner" "$(stat -c '%U' "$WORKSPACE")" \
  "$(cat "$FM_TEST_CLONE_USER_FILE" 2>/dev/null)"
unset FM_TEST_CLONE_USER_FILE

# --- Result ----------------------------------------------------------------

echo
if [ "$FAIL" -eq 0 ]; then
  fm_ok "$PASS passed"
else
  fm_err "$FAIL failed, $PASS passed"
  exit 1
fi
