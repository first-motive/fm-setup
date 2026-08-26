#!/usr/bin/env bash
#
# test-machine.sh — exercise the machine identity card end to end.
#
#   ./scripts/dev/test-machine.sh
#
# The card is a cross-repo contract: fm-tools resolves the workspace root from
# it, fm-comms renders zenoh's config from it, fm_ros2 derives its namespace
# from it, and fm-desktop decides between engineer and client mode on whether it
# exists at all. A change here that looks harmless is felt in four repos that do
# not run this repo's CI, which is why the writer is tested rather than trusted.
#
# Every case runs against FM_MACHINE_FILE in a temp directory, so nothing here
# touches /etc/fm or the developer's own card, and no case needs root.
#
# No test framework: this repo has no Python package and no test runner, and a
# dependency would have to be installed on every machine that provisions. The
# assertions below are three functions and a counter.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$_here/../.." && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$FM_ROOT/lib.sh"
# The card emitter reads the schema version from the manifest, as every writer
# does. machine.sh sources it for itself, so only the in-process cases need this.
# shellcheck source=../manifest.sh disable=SC1091
. "$FM_ROOT/scripts/manifest.sh"

MACHINE="$FM_ROOT/scripts/run/machine.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP
export FM_MACHINE_FILE="$TMP/machine.json"

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf '    %s✓%s %s\n' "${FM_C_GREEN}" "${FM_C_RESET}" "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '    %s✗%s %s\n' "${FM_C_RED}" "${FM_C_RESET}" "$1"; }

# assert_eq LABEL EXPECTED ACTUAL
assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"; printf '        expected: %s\n        actual:   %s\n' "$2" "$3"; fi
}

# assert_rc LABEL EXPECTED_CODE COMMAND… — run COMMAND, compare its exit code.
# Output is swallowed: several cases assert on a refusal, and a page of expected
# error text buries the one line that matters.
assert_rc() {
  local label="$1" want="$2"; shift 2
  local got=0
  "$@" >/dev/null 2>&1 || got=$?
  assert_eq "$label" "$want" "$got"
}

card() { "$MACHINE" "$@"; }
field() { jq -r "$1 // \"\"" "$FM_MACHINE_FILE"; }
fresh() { rm -f "$FM_MACHINE_FILE"; }

fm_require_cmd jq

fm_log "machine identity card"

# --- Writing ---------------------------------------------------------------

fresh
card init --role jetson --name fm-rec-01 --workspace /home/fm/fm >/dev/null
assert_eq "init writes schema_version" "1"           "$(field .schema_version)"
assert_eq "init writes name"           "fm-rec-01"   "$(field .name)"
assert_eq "init writes role"           "jetson"      "$(field .role)"
assert_eq "init defaults fleet"        "prod"        "$(field .fleet)"
assert_eq "init defaults transport"    "zenoh"       "$(field .transport)"
assert_eq "init writes workspace"      "/home/fm/fm" "$(field .workspace)"

# The optional field is absent, not empty or null: a consumer testing for the
# key must see it missing, and "workload": "" fails the card's own schema.
assert_eq "workload absent when not given" "false" "$(jq 'has("workload")' "$FM_MACHINE_FILE")"

# Field order is part of the contract in practice — a card is read by people as
# well as by jq, and a writer that shuffles keys makes every repair a noisy diff.
assert_eq "key order is stable" \
  "schema_version name role fleet transport workspace" \
  "$(jq -r 'keys_unsorted | join(" ")' "$FM_MACHINE_FILE")"

# --- Repair keeps what it was not asked to change ---------------------------

card init --fleet bench >/dev/null
assert_eq "repair changes the field given"   "bench"     "$(field .fleet)"
assert_eq "repair keeps name"                "fm-rec-01" "$(field .name)"
assert_eq "repair keeps role"                "jetson"    "$(field .role)"
assert_eq "repair keeps workspace"           "/home/fm/fm" "$(field .workspace)"

# --- Workload, the one optional field ---------------------------------------

card init --workload recorder >/dev/null
assert_eq "workload written when given" "recorder" "$(field .workload)"
assert_eq "workload sits before workspace" \
  "schema_version name role fleet transport workload workspace" \
  "$(jq -r 'keys_unsorted | join(" ")' "$FM_MACHINE_FILE")"

card init --transport dds-lan >/dev/null
assert_eq "workload carries forward" "recorder" "$(field .workload)"

card init --workload none >/dev/null
assert_eq "none clears workload" "false" "$(jq 'has("workload")' "$FM_MACHINE_FILE")"

card init --workload processor >/dev/null
card init --workload none >/dev/null
assert_eq "none clears rather than carrying forward" "false" "$(jq 'has("workload")' "$FM_MACHINE_FILE")"

# --- Refusals ---------------------------------------------------------------
#
# A rejected flag value is a usage error (2); an unmet precondition is 3. The
# split matters to the CLI's exit-code contract, so it is asserted, not assumed.

assert_rc "bad workload refused"  2 card init --workload nope
assert_rc "bad transport refused" 2 card init --transport carrier-pigeon
assert_rc "bad fleet refused"     2 card init --fleet "Prod"
assert_rc "bad role refused"      2 card init --role toaster
assert_rc "relative workspace refused" 2 card init --workspace relative/path
assert_rc "unknown verb refused"  2 card bogus
assert_rc "unknown flag refused"  2 card init --nonsense

# Name shape, and the cross-check that the abbreviation matches the role. The
# second is what stops a recorder publishing under the workstation's namespace.
assert_rc "digit in abbrev refused"     2 card init --role jetson --name fm-r1-01
assert_rc "empty abbrev refused"        2 card init --role jetson --name fm--01
assert_rc "single-digit index refused"  2 card init --role jetson --name fm-rec-1
assert_rc "uppercase name refused"      2 card init --role jetson --name fm-REC-01
assert_rc "abbrev must match role"      2 card init --role jetson --name fm-ws-01

# A refused write leaves the card as it was, rather than half-updated.
assert_eq "refusal does not touch the card" "bench" "$(field .fleet)"

# The validators are also exercised directly, because a case refused through the
# CLI can be refused by the wrong rule. "fm-REC-01" is caught by the role
# cross-check whether or not the uppercase rule works, which is exactly how a
# locale-collation bug hid here: under a UTF-8 locale the glob range a-z also
# matches uppercase, so `*[!a-z0-9-]*` accepted "Prod" and wrote it to the card.
assert_rc "valid_fleet rejects uppercase"      1 fm_machine_valid_fleet "Prod"
assert_rc "valid_fleet rejects all-caps"       1 fm_machine_valid_fleet "PROD"
assert_rc "valid_fleet rejects non-ascii"      1 fm_machine_valid_fleet "ünicode"
assert_rc "valid_fleet rejects a space"        1 fm_machine_valid_fleet "two words"
assert_rc "valid_fleet accepts a real fleet"   0 fm_machine_valid_fleet "bench-2"
assert_rc "valid_name rejects uppercase abbrev" 1 fm_machine_valid_name "fm-REC-01"
assert_rc "valid_name accepts a real name"      0 fm_machine_valid_name "fm-rec-01"
# The workstation half of the same rule, now that `flash --role workstation`
# writes cards too: fm-ws-01 is a workstation and nothing else.
assert_rc "valid_name accepts a workstation name" 0 fm_machine_valid_name "fm-ws-01" workstation
assert_rc "valid_name rejects a rig name for a workstation" 1 \
  fm_machine_valid_name "fm-rec-01" workstation

# --- Reading ----------------------------------------------------------------

fresh
card init --role jetson --name fm-rec-02 --workload robot >/dev/null

assert_eq "namespace is derived, not stored" "fm_rec_02" "$(fm_machine_namespace)"
assert_eq "namespace absent from the card"   "false"     "$(jq 'has("namespace")' "$FM_MACHINE_FILE")"
assert_eq "show --json adds the namespace"   "fm_rec_02" "$(card show --json | jq -r .namespace)"
assert_eq "optional reader returns the value" "robot"    "$(fm_machine_workload)"

card init --workload none >/dev/null
assert_eq "optional reader returns empty when absent" "" "$(fm_machine_workload)"
assert_rc "required reader fails on a missing field" 1 fm_machine_get workload

# --- Doctor -----------------------------------------------------------------

assert_rc "doctor passes a good card" 0 card doctor

# A hand-edited card is what doctor exists for, so each rule is checked through
# the file rather than through the writer that would have refused it.
jq '.transport = "carrier-pigeon"' "$FM_MACHINE_FILE" >"$TMP/x" && mv "$TMP/x" "$FM_MACHINE_FILE"
assert_rc "doctor catches a bad transport" 3 card doctor

jq '.transport = "zenoh" | .workload = "nope"' "$FM_MACHINE_FILE" >"$TMP/x" && mv "$TMP/x" "$FM_MACHINE_FILE"
assert_rc "doctor catches a bad workload" 3 card doctor

jq 'del(.workload)' "$FM_MACHINE_FILE" >"$TMP/x" && mv "$TMP/x" "$FM_MACHINE_FILE"
assert_rc "doctor accepts an absent workload" 0 card doctor

jq '.schema_version = 99' "$FM_MACHINE_FILE" >"$TMP/x" && mv "$TMP/x" "$FM_MACHINE_FILE"
assert_rc "doctor refuses an unknown schema_version" 3 card doctor

printf 'not json' >"$FM_MACHINE_FILE"
assert_rc "doctor refuses a malformed card" 3 card doctor
assert_eq "optional reader survives a malformed card" "" "$(fm_machine_workload)"

# --- Absence is legitimate --------------------------------------------------
#
# A laptop running the desktop app in client mode has no card and is not broken.

fresh
assert_rc "doctor reports a missing card as a precondition" 3 card doctor
assert_rc "show reports a missing card as a precondition"   3 card show
assert_rc "reset on a missing card succeeds"                0 card reset -y
assert_eq "exists() is false with no card"    "no" "$(fm_machine_exists && echo yes || echo no)"
assert_eq "optional reader is empty with no card" "" "$(fm_machine_workload)"

# --- Reset ------------------------------------------------------------------

card init --role jetson --name fm-rec-03 >/dev/null
assert_eq "card exists before reset" "yes" "$(fm_machine_exists && echo yes || echo no)"
card reset -y >/dev/null
assert_eq "reset removes the card"   "no"  "$(fm_machine_exists && echo yes || echo no)"

# --- The flashed card -------------------------------------------------------
#
# `flash` seeds a card before the machine exists, without jq. That writer shipped
# a card no reader could parse: a `\"` meant for a heredoc landed inside the
# JSON, `jq` refused the file, the role fell back to detection, and the rig
# provisioned as nothing at all. These assert the emitter produces JSON, and that
# it agrees with the jq writer rather than drifting beside it.

literal="$(fm_machine_card_literal fm-rec-09 jetson canary zenoh recorder /home/fm/fm)"
assert_eq "flashed card is valid JSON" "ok" \
  "$(printf '%s' "$literal" | jq -e . >/dev/null 2>&1 && echo ok || echo INVALID)"
assert_eq "flashed card carries the role" "jetson" \
  "$(printf '%s' "$literal" | jq -r .role)"
assert_eq "flashed card carries the workload" "recorder" \
  "$(printf '%s' "$literal" | jq -r .workload)"

bare="$(fm_machine_card_literal fm-rec-09 jetson canary zenoh "" /home/fm/fm)"
assert_eq "flashed card is valid JSON with no workload" "ok" \
  "$(printf '%s' "$bare" | jq -e . >/dev/null 2>&1 && echo ok || echo INVALID)"
assert_eq "workload key omitted when empty" "false" \
  "$(printf '%s' "$bare" | jq 'has("workload")')"

# The two writers must describe one document. Compared as parsed JSON, so
# whitespace and key order are not what is being asserted.
card init --role jetson --name fm-rec-09 --fleet canary --transport zenoh \
  --workload recorder --workspace /home/fm/fm >/dev/null
assert_eq "both card writers agree" "same" \
  "$([ "$(jq -S . "$FM_MACHINE_FILE")" = "$(printf '%s' "$literal" | jq -S .)" ] && echo same || echo DIFFERENT)"

# --- Role detection ---------------------------------------------------------
#
# Wrong here is not a mild misdetection: a Jetson resolved as `workstation`
# targets another Ubuntu and another ROS distro, and does not provision at all.
# An Orin Nano says "tegra" in its compatible string and not in its model.

dt="$TMP/dt" && mkdir -p "$dt"
printf 'nvidia,p3768-0000+p3767-0005-super\0nvidia,tegra234\0' > "$dt/compatible"
printf 'NVIDIA Jetson Orin Nano Engineering Reference Developer Kit Super\0' > "$dt/model"
assert_eq "orin nano detects as jetson" "jetson" "$(FM_DEVICE_TREE="$dt" fm_detect_role)"

dt2="$TMP/dt2" && mkdir -p "$dt2"
printf 'nvidia,tegra234\0' > "$dt2/compatible"
assert_eq "compatible alone is enough" "jetson" "$(FM_DEVICE_TREE="$dt2" fm_detect_role)"

dt3="$TMP/dt3" && mkdir -p "$dt3"
printf 'Some Jetson Board\0' > "$dt3/model"
assert_eq "model alone is enough" "jetson" "$(FM_DEVICE_TREE="$dt3" fm_detect_role)"

dt4="$TMP/dt4" && mkdir -p "$dt4"
printf 'Dell Precision 7960 Tower\0' > "$dt4/model"
printf 'dell,precision-7960\0' > "$dt4/compatible"
assert_eq "a tower is not a jetson" "workstation" "$(FM_DEVICE_TREE="$dt4" fm_detect_role)"

dt5="$TMP/dt5" && mkdir -p "$dt5"
assert_eq "no device tree at all is a workstation" "workstation" "$(FM_DEVICE_TREE="$dt5" fm_detect_role)"

# --- Result -----------------------------------------------------------------

echo
if [ "$FAIL" -gt 0 ]; then
  fm_err "$FAIL failed, $PASS passed"
  exit 1
fi
fm_ok "$PASS passed"
