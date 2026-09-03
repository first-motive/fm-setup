#!/usr/bin/env bash
#
# test-supply-chain.sh — exercise the two pins that stand between a provision
# and code somebody else chose.
#
#   ./scripts/dev/test-supply-chain.sh
#
# Two steps fetch trust anchors over the network and act on them as root: 35
# installs four packages from an apt repo whose signing key it downloads, and 60
# runs Tailscale's installer script. Both are pinned — the key by fingerprint,
# the script by SHA256 — and a pin that is never exercised is a pin nobody knows
# is wired up. What matters is the refusal: a wrong key or a rewritten script
# must stop the step before anything is installed, and must say what to do.
#
# Neither pin can be proved against the real thing here. That needs the network
# and a machine to provision, and a test that reaches nvidia.github.io fails for
# reasons unrelated to this code. So a fake curl, gpg, apt-get and sudo go on
# PATH ahead of the real ones, and each step's fetch-and-verify function is
# called directly. Nothing here needs root and nothing leaves the temp
# directory.
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

# Both steps call fm_require_linux at source time. The suite says so rather than
# failing halfway through on a developer's Mac.
[ "$(uname -s)" = "Linux" ] || { fm_warn "these are Linux steps — skipping on $(uname -s)"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '    %s✓%s %s\n' "${FM_C_GREEN}" "${FM_C_RESET}" "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '    %s✗%s %s\n' "${FM_C_RED}" "${FM_C_RESET}" "$1"; }

# assert_eq LABEL EXPECTED ACTUAL
assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"; printf '        expected: %s\n        actual:   %s\n' "$2" "$3"; fi
}

# assert_contains LABEL NEEDLE HAYSTACK — a message is part of the contract when
# it is the only thing telling an operator how to fix a stopped provision.
assert_contains() {
  case "$3" in
    *"$2"*) ok "$1" ;;
    *) bad "$1"; printf '        expected to contain: %s\n' "$2" ;;
  esac
}

# --- The pins themselves ----------------------------------------------------
#
# A blank or malformed pin verifies nothing while still looking pinned, and both
# constants are edited by hand whenever upstream rotates.

assert_eq "the NVIDIA key fingerprint is 40 uppercase hex digits" "match" \
  "$(case "$FM_NVIDIA_KEY_FPR" in [0-9A-F]*) [ "${#FM_NVIDIA_KEY_FPR}" = 40 ] && echo match ;; esac)"
assert_eq "the tailscale installer checksum is 64 lowercase hex digits" "match" \
  "$(case "$FM_TAILSCALE_INSTALLER_SHA256" in [0-9a-f]*) [ "${#FM_TAILSCALE_INSTALLER_SHA256}" = 64 ] && echo match ;; esac)"
assert_eq "the tailscale version is pinned" "match" \
  "$(case "$FM_TAILSCALE_VERSION" in [0-9]*.[0-9]*) echo match ;; esac)"

# --- The fake machine -------------------------------------------------------
#
# sudo is transparent, as in test-ledger.sh. apt-get and tee do nothing: what is
# under test is whether the step reaches them at all.

BIN="$TMP/bin"
mkdir -p "$BIN"
export PATH="$BIN:$PATH"

cat > "$BIN/sudo" <<'FAKE'
#!/usr/bin/env bash
exec env "$@"
FAKE

cat > "$BIN/apt-get" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE

# KEY_FPR is what the fake gpg reports the downloaded key to be, so a rotation
# upstream is staged by writing a different value into it.
export KEY_FPR="$TMP/key-fpr"

cat > "$BIN/gpg" <<'FAKE'
#!/usr/bin/env bash
# Two modes, matching the two the steps use: --dearmor writes what it is given
# to -o, and --show-keys reports a fingerprint in gpg's colon format.
out=""
mode=""
prev=""
for arg in "$@"; do
  case "$prev" in -o) out="$arg" ;; esac
  case "$arg" in
    --dearmor|--show-keys) mode="$arg" ;;
  esac
  prev="$arg"
done
case "$mode" in
  --dearmor) cat > "$out" ;;
  --show-keys) printf 'fpr:::::::::%s:\n' "$(cat "$KEY_FPR")" ;;
  *) exit 1 ;;
esac
FAKE

# CURL_BODY is what the fake curl serves for any URL, so a tampered key or a
# rewritten installer is staged by writing a different body into it.
export CURL_BODY="$TMP/curl-body"

cat > "$BIN/curl" <<'FAKE'
#!/usr/bin/env bash
out=""
prev=""
for arg in "$@"; do
  case "$prev" in -o) out="$arg" ;; esac
  prev="$arg"
done
if [ -n "$out" ]; then cat "$CURL_BODY" > "$out"; else cat "$CURL_BODY"; fi
FAKE

chmod +x "$BIN"/*

# run_step_fn STEP FUNCTION… — source a step, then call one of its functions.
#
# `check` as the dispatch argument rather than nothing: a step ends in
# `fm_dispatch "$@"`, which defaults to install, and install is the mode that
# provisions. check reports and changes nothing, which leaves the file's
# functions defined and costs nothing to have run.
run_step_fn() {
  local step="$1"; shift
  # shellcheck disable=SC1090
  ( . "$FM_ROOT/scripts/steps/$step" check >/dev/null 2>&1 || true; "$@" ) 2>&1
}

# --- 35: the NVIDIA signing key --------------------------------------------

KEYRING="$TMP/nvidia-keyring.gpg"
SOURCES="$TMP/nvidia.list"
export FM_NVIDIA_KEYRING="$KEYRING" FM_NVIDIA_SOURCES="$SOURCES"
printf 'a key, armoured\n' > "$CURL_BODY"

# A rotated or substituted key. The step must stop here: everything after this
# line is apt installing four packages as root on that key's authority.
printf 'DEADBEEF0000000000000000000000000000BEEF\n' > "$KEY_FPR"
out="$(run_step_fn 35-nvidia-container-toolkit.sh add_repo && echo RC=0 || echo RC=1)"
assert_contains "a wrong key fails add_repo" "RC=1" "$out"
assert_contains "the mismatch names the expected fingerprint" "$FM_NVIDIA_KEY_FPR" "$out"
assert_contains "the mismatch names the actual fingerprint" "DEADBEEF" "$out"
assert_contains "the mismatch says which constant to update" "FM_NVIDIA_KEY_FPR in scripts/manifest.sh" "$out"
assert_eq "a wrong key leaves no keyring behind" "false" \
  "$([ -e "$KEYRING" ] && echo true || echo false)"
assert_eq "a wrong key adds no apt source" "false" \
  "$([ -e "$SOURCES" ] && echo true || echo false)"

# The pinned key. The repo is added and apt is allowed to see it.
printf '%s\n' "$FM_NVIDIA_KEY_FPR" > "$KEY_FPR"
out="$(run_step_fn 35-nvidia-container-toolkit.sh add_repo && echo RC=0 || echo RC=1)"
assert_contains "the pinned key passes add_repo" "RC=0" "$out"
assert_eq "the pinned key adds the apt source" "true" \
  "$([ -e "$SOURCES" ] && echo true || echo false)"

# --- 60: the Tailscale installer -------------------------------------------
#
# The installer under test writes the version it was handed and nothing else, so
# a case that reaches it is visible without installing anything.

RAN="$TMP/installer-ran"
cat > "$CURL_BODY" <<FAKE
#!/bin/sh
printf '%s' "\${TAILSCALE_VERSION:-unset}" > "$RAN"
FAKE

# A rewritten installer — which is what upstream's next edit to that one
# unversioned URL looks like from here.
out="$(run_step_fn 60-tailscale.sh install_tailscale && echo RC=0 || echo RC=1)"
assert_contains "an unpinned installer fails install_tailscale" "RC=1" "$out"
assert_contains "the mismatch names the expected checksum" "$FM_TAILSCALE_INSTALLER_SHA256" "$out"
assert_contains "the mismatch says which constant to update" "FM_TAILSCALE_INSTALLER_SHA256 in" "$out"
assert_contains "the mismatch says how to re-derive it" "sha256sum" "$out"
assert_eq "an unpinned installer never runs" "false" \
  "$([ -e "$RAN" ] && echo true || echo false)"

# The matching installer. The pin is re-pointed at this fixture rather than the
# fixture at the pin, because no fixture can be made to hash to a given value.
fixture_sha="$(sha256sum "$CURL_BODY" | cut -d' ' -f1)"
out="$(run_step_fn 60-tailscale.sh \
  eval "FM_TAILSCALE_INSTALLER_SHA256=$fixture_sha; install_tailscale" && echo RC=0 || echo RC=1)"
assert_contains "a matching installer passes install_tailscale" "RC=0" "$out"
assert_eq "a matching installer runs" "true" \
  "$([ -e "$RAN" ] && echo true || echo false)"
assert_eq "the installer is handed the pinned version" "$FM_TAILSCALE_VERSION" "$(cat "$RAN" 2>/dev/null)"

# --- Result ----------------------------------------------------------------

echo
if [ "$FAIL" -eq 0 ]; then
  fm_ok "$PASS passed"
else
  fm_err "$FAIL failed, $PASS passed"
  exit 1
fi
