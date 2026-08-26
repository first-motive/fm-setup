#!/usr/bin/env bash
#
# test-flash.sh — build both flash seeds and check them, without writing media.
#
#   ./scripts/dev/test-flash.sh
#
# A seed is the one artefact in this repo nobody can correct after the fact: it
# is baked onto a stick, handed to a machine that is not yet reachable, and read
# by an installer that reports a malformed answer file as a blank screen. The
# only place to find a mistake in one is here.
#
# Everything runs against a temp directory. Nothing is written to a device, no
# image is downloaded, and no case needs root.
#
# `cloud-init` and `python3` are used when present and skipped when not: this
# script has to be runnable on the macOS laptop that flashes the cards, and the
# CI job installs both so the full set runs there.
#
# No test framework, for the reason test-machine.sh gives: three functions and a
# counter, and nothing to install on a machine that provisions.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$_here/../.." && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$FM_ROOT/lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$FM_ROOT/scripts/manifest.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); printf '    %s✓%s %s\n' "${FM_C_GREEN}" "${FM_C_RESET}" "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '    %s✗%s %s\n' "${FM_C_RED}" "${FM_C_RESET}" "$1"; }

assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"; printf '        expected: %s\n        actual:   %s\n' "$2" "$3"; fi
}

# assert_rc LABEL EXPECTED_CODE COMMAND… — output swallowed, as in test-machine.sh:
# several cases assert on a refusal, and its error text buries the line that matters.
assert_rc() {
  local label="$1" want="$2"; shift 2
  local got=0
  "$@" >/dev/null 2>&1 || got=$?
  assert_eq "$label" "$want" "$got"
}

skip() { printf '    %s↷ %s (skip)%s\n' "${FM_C_DIM}" "$1" "${FM_C_RESET}"; }

# --- Fixtures ---------------------------------------------------------------

KEYS="$TMP/authorized_keys"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITEST test@fixture\n' >"$KEYS"

# A hash of the right shape and no value: the installer wants a crypt string,
# and the seed refuses a plaintext one, so the fixture has to look like one.
# shellcheck disable=SC2016  # a crypt hash is literal $-signs, not expansions
PW_HASH='$6$rounds=4096$fixture$0123456789abcdef'

SETUP_URL="https://raw.githubusercontent.com/first-motive/fm-setup/v0.0.0-test/install.sh"
ROS2_URL="https://raw.githubusercontent.com/first-motive/fm-ros2/v0.0.0-test/install.sh"

seed() {
  local role="$1" out="$2"; shift 2
  FM_GH_TOKEN=testtoken FM_TS_AUTHKEY=tskey-test \
    bash "$FM_ROOT/scripts/internal/seed-$role.sh" --out "$out" \
      --authorized-keys "$KEYS" --setup-url "$SETUP_URL" --ros2-url "$ROS2_URL" "$@"
}

# extract_written_file USER_DATA PATH — echo one write_files `content: |` block,
# de-indented. Both seeds carry the identity card and the first-boot script this
# way, at different depths, so the block's own first line sets the indent.
extract_written_file() {
  awk -v want="$2" '
    $1 == "-" && $2 == "path:" { grab = 0; found = ($3 == want); next }
    found && /^ *content: \|$/ { grab = 1; indent = -1; found = 0; next }
    grab {
      if ($0 ~ /^ *- path:/ || $0 ~ /^ *runcmd:/ || $0 ~ /^[^ ]/) { exit }
      if (indent < 0) { match($0, /^ */); indent = RLENGTH }
      print substr($0, indent + 1)
    }
  ' "$1"
}

# yaml_ok FILE — return success when FILE parses as YAML.
yaml_ok() {
  # python3 rather than `uv run`: the runner that has cloud-init already has the
  # interpreter and PyYAML that cloud-init itself depends on, and this is a lint
  # of a generated file rather than Python this project owns.
  python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$1"
}

fm_log "flash seeds"

# --- The jetson seed --------------------------------------------------------

JETSON="$TMP/jetson"; mkdir -p "$JETSON"
seed jetson "$JETSON" --name fm-rec-01 --workload recorder --wifi "rig-lan:secret"

for f in user-data network-config meta-data; do
  assert_eq "jetson seed writes $f" "yes" "$([ -s "$JETSON/$f" ] && echo yes || echo no)"
done

card="$(extract_written_file "$JETSON/user-data" "$FM_MACHINE_FILE_LINUX")"
assert_eq "jetson card is valid JSON" "ok" \
  "$(printf '%s' "$card" | jq -e . >/dev/null 2>&1 && echo ok || echo INVALID)"
assert_eq "jetson card carries the role" "jetson" "$(printf '%s' "$card" | jq -r .role)"
assert_eq "jetson card carries the name" "fm-rec-01" "$(printf '%s' "$card" | jq -r .name)"

boot="$TMP/first-boot-jetson.sh"
extract_written_file "$JETSON/user-data" /usr/local/sbin/fm-first-boot.sh >"$boot"
assert_rc "jetson first-boot script parses" 0 bash -n "$boot"
assert_eq "jetson first boot installs the recorder" "yes" \
  "$(grep -q -- '--recorder --service' "$boot" && echo yes || echo no)"
assert_eq "jetson first boot marks a failure" "yes" \
  "$(grep -q "$FM_FIRST_BOOT_FAILED" "$boot" && echo yes || echo no)"

assert_eq "the wifi psk reaches network-config" "yes" \
  "$(grep -q 'password: "secret"' "$JETSON/network-config" && echo yes || echo no)"

# --- The workstation seed ---------------------------------------------------

WS="$TMP/workstation"; mkdir -p "$WS"
seed workstation "$WS" --name fm-ws-01 --workload processor --password-hash "$PW_HASH"

for f in user-data meta-data; do
  assert_eq "workstation seed writes $f" "yes" "$([ -s "$WS/$f" ] && echo yes || echo no)"
done

card="$(extract_written_file "$WS/user-data" "$FM_MACHINE_FILE_LINUX")"
assert_eq "workstation card is valid JSON" "ok" \
  "$(printf '%s' "$card" | jq -e . >/dev/null 2>&1 && echo ok || echo INVALID)"
assert_eq "workstation card carries the role" "workstation" "$(printf '%s' "$card" | jq -r .role)"

boot="$TMP/first-boot-workstation.sh"
extract_written_file "$WS/user-data" /usr/local/sbin/fm-first-boot.sh >"$boot"
assert_rc "workstation first-boot script parses" 0 bash -n "$boot"
assert_eq "workstation first boot installs the processor" "yes" \
  "$(grep -q -- '--processor --service' "$boot" && echo yes || echo no)"

# The answers that were click-through steps until this seed existed. Each is a
# screen the installer stops on when it is missing.
for key in 'interactive-sections: []' 'ubuntu-desktop-minimal' 'allow-pw: false' 'snaps: []' 'name: direct'; do
  assert_eq "autoinstall answers '$key'" "yes" \
    "$(grep -qF "$key" "$WS/user-data" && echo yes || echo no)"
done

# --- Refusals ---------------------------------------------------------------

assert_rc "workstation seed refuses without a password hash" 1 \
  env -u FM_FLASH_PASSWORD_HASH bash "$FM_ROOT/scripts/internal/seed-workstation.sh" \
    --out "$WS" --name fm-ws-01 --authorized-keys "$KEYS" \
    --setup-url "$SETUP_URL" --ros2-url "$ROS2_URL"
assert_rc "workstation seed refuses a plaintext password" 1 \
  seed workstation "$WS" --name fm-ws-01 --password-hash hunter2
assert_rc "workstation seed refuses a recorder name" 1 \
  seed workstation "$WS" --name fm-rec-01 --password-hash "$PW_HASH"
assert_rc "jetson seed refuses a workstation name" 1 seed jetson "$JETSON" --name fm-ws-01
assert_rc "a seed refuses an unreadable key file" 1 \
  bash "$FM_ROOT/scripts/internal/seed-jetson.sh" --out "$JETSON" --name fm-rec-01 \
    --authorized-keys "$TMP/nope" --setup-url "$SETUP_URL" --ros2-url "$ROS2_URL"
assert_rc "a seed refuses a malformed token" 1 \
  env FM_GH_TOKEN='x"; rm -rf /; #' bash "$FM_ROOT/scripts/internal/seed-jetson.sh" \
    --out "$JETSON" --name fm-rec-01 --authorized-keys "$KEYS" \
    --setup-url "$SETUP_URL" --ros2-url "$ROS2_URL"

# --- The verb ---------------------------------------------------------------
#
# A dry run resolves the image, the refs, and every card field, and writes
# nothing — which is the whole plan a real flash would then act on.

# Two callers, because the password hash belongs to one role and is refused on
# the other: a single helper that exported it would fail every jetson case.
flash() { env -u FM_FLASH_PASSWORD_HASH bash "$FM_ROOT/scripts/run/flash.sh" "$@"; }
flash_ws() { FM_FLASH_PASSWORD_HASH="$PW_HASH" bash "$FM_ROOT/scripts/run/flash.sh" "$@"; }

assert_rc "jetson dry run"      0 flash --role jetson --dry-run
assert_rc "workstation dry run" 0 flash_ws --role workstation --name fm-ws-01 --dry-run
assert_rc "a name that contradicts the role is refused" 2 \
  flash_ws --role workstation --name fm-rec-01 --dry-run
assert_rc "an unknown role is refused" 2 flash --role toaster --dry-run
assert_rc "the workstation refuses to flash without a password" 2 \
  flash --role workstation --name fm-ws-01 --dry-run
assert_rc "--wifi is refused on the workstation" 2 \
  flash_ws --role workstation --name fm-ws-01 --wifi "x:y" --dry-run
assert_rc "--password-hash is refused on the jetson" 2 \
  flash --role jetson --password-hash "$PW_HASH" --dry-run

plan="$(flash_ws --role workstation --name fm-ws-01 --dry-run 2>&1)"
assert_eq "the workstation plan names the ISO" "yes" \
  "$(printf '%s' "$plan" | grep -q "$(basename "$FM_IMAGE_URL_WORKSTATION")" && echo yes || echo no)"
assert_eq "the workstation plan has nothing to decompress" "yes" \
  "$(printf '%s' "$plan" | grep -q '\.xz' && echo no || echo yes)"
assert_eq "the workstation plan prints both refs" "yes" \
  "$(printf '%s' "$plan" | grep -q 'refs ' && echo yes || echo no)"

# --- Schema -----------------------------------------------------------------
#
# The checks above prove the seed says what we meant. These prove cloud-init
# agrees, which is the only opinion that decides whether a stick boots.

if fm_has_cmd python3 && python3 -c 'import yaml' >/dev/null 2>&1; then
  assert_rc "jetson user-data is YAML"         0 yaml_ok "$JETSON/user-data"
  assert_rc "jetson network-config is YAML"    0 yaml_ok "$JETSON/network-config"
  assert_rc "workstation user-data is YAML"    0 yaml_ok "$WS/user-data"
else
  skip "YAML parse (no python3 with PyYAML)"
fi

if fm_has_cmd cloud-init; then
  assert_rc "jetson user-data passes cloud-init schema" 0 \
    cloud-init schema --config-file "$JETSON/user-data"

  # The workstation's own file is an autoinstall document, which cloud-init does
  # not have a schema for — subiquity owns that one. What cloud-init can check
  # is the cloud-config nested inside it, which is the half that runs on the
  # installed machine and the half this repo wrote.
  python3 -c '
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
nested = doc["autoinstall"]["user-data"]
with open(sys.argv[2], "w") as f:
    f.write("#cloud-config\n")
    yaml.safe_dump(nested, f)
' "$WS/user-data" "$TMP/nested-user-data"
  assert_rc "the workstation's nested cloud-config passes cloud-init schema" 0 \
    cloud-init schema --config-file "$TMP/nested-user-data"
else
  skip "cloud-init schema (cloud-init not installed)"
fi

# --- Result -----------------------------------------------------------------

echo
if [ "$FAIL" -gt 0 ]; then
  fm_err "$FAIL failed, $PASS passed"
  exit 1
fi
fm_ok "$PASS passed"
