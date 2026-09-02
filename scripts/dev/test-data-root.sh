#!/usr/bin/env bash
#
# test-data-root.sh — exercise the machine's data root.
#
#   ./scripts/dev/test-data-root.sh
#
# The step lays out the one tree on a host that holds episodes, and two of its
# properties are worth a test rather than a reading. It must be idempotent,
# because the appliance converge runs it unattended on every tag; and it must
# resolve its path from the identity card alone, because FM_HOME is per person
# and a data root that follows whoever is logged in splits the recordings across
# two paths that both look correct.
#
# Runs against a card and a workspace in a temp directory, so nothing here
# touches /etc/fm, /opt/fm, or the developer's own machine, and no case needs
# root. The fm group does not exist on a runner; the step reports that and sets
# the mode anyway, which is the case this asserts.
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

# `stat -c` and the step's own fm_require_linux are both GNU/Linux. The suite
# says so rather than failing halfway through on a developer's Mac.
[ "$(uname -s)" = "Linux" ] || { fm_warn "data root is a Linux step — skipping on $(uname -s)"; exit 0; }
fm_require_cmd jq

STEP="$FM_ROOT/scripts/steps/13-data-root.sh"
MACHINE="$FM_ROOT/scripts/run/machine.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP
export FM_MACHINE_FILE="$TMP/machine.json"
WORKSPACE="$TMP/ws"
DATA="$WORKSPACE/$FM_DATA_ROOT_NAME"
mkdir -p "$WORKSPACE"

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
  local label="$1" want="$2"; shift 2
  local got=0
  "$@" >/dev/null 2>&1 || got=$?
  assert_eq "$label" "$want" "$got"
}

step() { bash "$STEP" "$@"; }
mode() { stat -c '%a' "$1" 2>/dev/null || echo missing; }

fm_log "machine data root"

# The card is written by the real writer rather than by hand, so a change to
# either one shows up here. `trainer` because it is the role this tree was added
# alongside, and writing one proves the card accepts it.
"$MACHINE" init --role trainer --name fm-trn-01 --workspace "$WORKSPACE" >/dev/null

# --- Layout ----------------------------------------------------------------

# FM_HOME is set to somewhere else entirely for the whole run. The step must
# ignore it: this is the assertion the rest of the suite exists to protect.
export FM_HOME="$TMP/somebody-else"

assert_rc "install exits 0" 0 step install

assert_eq "root is mode 3775" "3775" "$(mode "$DATA")"
for sub in "${FM_DATA_ROOT_SUBDIRS[@]}"; do
  assert_eq "$sub is mode 3775" "3775" "$(mode "$DATA/$sub")"
done

assert_eq "FM_HOME is not the data root" "false" \
  "$([ -e "$FM_HOME" ] && echo true || echo false)"

# --- Idempotence -----------------------------------------------------------
#
# The converge timer runs this unattended on every tag, so a second run has to
# be a no-op and not a repair. Asserted on the tree's own state rather than on
# the log, because the log is allowed to differ and the modes are not.

before="$(find "$DATA" -printf '%p %m\n' | LC_ALL=C sort)"
assert_rc "a second install exits 0" 0 step install
assert_eq "a second install changes nothing" "$before" \
  "$(find "$DATA" -printf '%p %m\n' | LC_ALL=C sort)"

# --- check is read-only ----------------------------------------------------

assert_rc "check exits 0 on a laid-out tree" 0 step check
assert_eq "check changes nothing" "$before" \
  "$(find "$DATA" -printf '%p %m\n' | LC_ALL=C sort)"

rm -rf "$DATA"
assert_rc "check exits 0 with no tree at all" 0 step check
assert_eq "check created nothing" "false" \
  "$([ -e "$DATA" ] && echo true || echo false)"

# --- A partial card is not a crash -----------------------------------------
#
# The converge path reads a card this step did not write. `scripts/update.sh`
# reaches every machine unattended on a tag, and the card it finds may carry a
# role and nothing else — which is exactly the card converge-check.sh stages.
# Resolving the workspace by demanding the field aborted the whole `--check`
# there, breaking the contract that a check always exits 0, on every role that
# lists this step rather than on the trainer alone.

partial="$TMP/partial.json"
printf '{"role":"trainer"}\n' > "$partial"
assert_rc "check exits 0 on a card with no workspace" 0 \
  env FM_MACHINE_FILE="$partial" bash "$STEP" check

# --- A card cannot point the tree outside the workspace ---------------------
#
# The card is validated when it is written, not when it is read, and this step
# takes its workspace straight into mkdir, chgrp and chmod. A relative path or a
# `..` segment must stop the step rather than build the tree somewhere else.

relative="$TMP/relative.json"
printf '{"role":"trainer","workspace":"fm"}\n' > "$relative"
assert_rc "a relative workspace is refused" 1 \
  env FM_MACHINE_FILE="$relative" bash "$STEP" install

escaping="$TMP/escaping.json"
printf '{"role":"trainer","workspace":"%s/../escaped"}\n' "$TMP" > "$escaping"
assert_rc "a workspace with a '..' segment is refused" 1 \
  env FM_MACHINE_FILE="$escaping" bash "$STEP" install
assert_eq "the refused workspace created nothing" "false" \
  "$([ -e "$TMP/../escaped" ] && echo true || echo false)"

# --- uninstall keeps the data ----------------------------------------------
#
# Recordings and releases are the machine's irreplaceables. An uninstall that
# removed them would be the one failure in this repo with no undo.

step install >/dev/null
assert_rc "uninstall exits 0" 0 step uninstall
assert_eq "uninstall leaves the tree in place" "true" \
  "$([ -d "$DATA/recordings" ] && echo true || echo false)"

# --- Result ----------------------------------------------------------------

echo
if [ "$FAIL" -eq 0 ]; then
  fm_ok "$PASS passed"
else
  fm_err "$FAIL failed, $PASS passed"
  exit 1
fi
