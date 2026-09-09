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
if [ "${1:-}" = -n ]; then shift; fi
for arg in "$@"; do
  case "$arg" in /etc/fm-archive-uploader.env) exit 97 ;; esac
done
exec env "$@"
FAKE

cat > "$BIN/fm" <<'FAKE'
#!/usr/bin/env bash
case " $* " in
  *" archive preflight "*|*" data-archive preflight "*)
    [ "${FM_ARCHIVE_PREFLIGHT_FAIL:-0}" = 1 ] && exit 1
    printf '%s\n' '{"checks":{"writer_scope":"pass"}}'
    ;;
  *) exit 2 ;;
esac
FAKE

cat > "$BIN/systemctl" <<'FAKE'
#!/usr/bin/env bash
case "${1:-}" in
  cat) exit 0 ;;
  is-active)
    state="$(cat "$FM_ARCHIVE_ACTIVE_FILE")"
    [ "$state" = active ] && printf 'active\n' && exit 0 || printf '%s\n' "$state" && exit 3
    ;;
  restart)
    printf '%s\n' restart >>"$FM_ARCHIVE_SYSTEMCTL_LOG"
    if [ "${FM_ARCHIVE_RESTART_FAIL:-0}" = 1 ]; then exit 1; fi
    # Disabling derived discovery leaves raw recording uploads running.
    printf 'active\n' >"$FM_ARCHIVE_ACTIVE_FILE"
    exit 0
    ;;
  *) exit 0 ;;
esac
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
  if [ "$step" = 95-archive-derived.sh ]; then
    ( . "$FM_ROOT/scripts/steps/$step" check >/dev/null 2>&1 || true; export ENVFILE="$ARCHIVE_ENV"; "$@" ) 2>&1
  else
    ( . "$FM_ROOT/scripts/steps/$step" check >/dev/null 2>&1 || true; "$@" ) 2>&1
  fi
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

# --- 95: the derived archive opt-in ----------------------------------------
#
# The fake sudo refuses the real service path. The step is sourced first, then
# its path variable is pointed at this temporary fixture, so this test cannot
# inspect or mutate a live credential file.
ARCHIVE_ENV="$TMP/fm-archive-uploader.env"
ARCHIVE_ACTIVE="$TMP/archive-active"
ARCHIVE_SYSTEMCTL_LOG="$TMP/systemctl.log"
export ARCHIVE_ENV FM_ARCHIVE_ENVFILE="$ARCHIVE_ENV" \
  FM_ARCHIVE_ACTIVE_FILE="$ARCHIVE_ACTIVE" FM_ARCHIVE_SYSTEMCTL_LOG="$ARCHIVE_SYSTEMCTL_LOG"
cat >"$ARCHIVE_ENV" <<'EOF'
FM_ARCHIVE_UPLOADER_ENABLED=true
BACKBLAZE_B2_FMREC_KEY_ID=secret-id
BACKBLAZE_B2_FMREC_APPLICATION_KEY=secret-key
FM_ARCHIVE_UPLOADER_DERIVED_ENABLED=false
FM_ARCHIVE_UPLOADER_DELETE_ENABLED=false
KEEP_THIS_BYTE=unchanged
EOF
chmod 600 "$ARCHIVE_ENV"
printf 'active\n' >"$ARCHIVE_ACTIVE"
printf '%s\n' untouched >"$ARCHIVE_SYSTEMCTL_LOG"
ARCHIVE_BEFORE="$(sha256sum "$ARCHIVE_ENV")"

assert_contains "derived opt-in requires provider preflight" "RC=1" "$(FM_ARCHIVE_PREFLIGHT_FAIL=1 run_step_fn 95-archive-derived.sh do_install && echo RC=0 || echo RC=1)"
assert_eq "provider refusal leaves env bytes unchanged" "$ARCHIVE_BEFORE" "$(sha256sum "$ARCHIVE_ENV")"
out="$(run_step_fn 95-archive-derived.sh do_install && echo RC=0 || echo RC=1)"
assert_eq "provider output does not contain credentials" false \
  "$(printf '%s' "$out" | grep -Eq 'secret-(id|key)' && echo true || echo false)"
assert_contains "derived opt-in enables the flag" "RC=0" "$out"
assert_eq "derived flag is true" true "$(sed -n 's/^FM_ARCHIVE_UPLOADER_DERIVED_ENABLED=//p' "$ARCHIVE_ENV")"
assert_eq "raw uploader remains enabled" true "$(sed -n 's/^FM_ARCHIVE_UPLOADER_ENABLED=//p' "$ARCHIVE_ENV")"
assert_eq "deletion remains disabled" false "$(sed -n 's/^FM_ARCHIVE_UPLOADER_DELETE_ENABLED=//p' "$ARCHIVE_ENV")"
assert_eq "derived flag occurs once" 1 "$(grep -c '^FM_ARCHIVE_UPLOADER_DERIVED_ENABLED=' "$ARCHIVE_ENV")"
assert_eq "credential remains private" 600 "$(stat -c '%a' "$ARCHIVE_ENV")"
restarts="$(wc -l <"$ARCHIVE_SYSTEMCTL_LOG")"
run_step_fn 95-archive-derived.sh do_install >/dev/null
assert_eq "repeated enable does not restart" "$restarts" "$(wc -l <"$ARCHIVE_SYSTEMCTL_LOG")"
run_step_fn 95-archive-derived.sh do_uninstall >/dev/null
assert_eq "disable clears only the derived flag" false "$(sed -n 's/^FM_ARCHIVE_UPLOADER_DERIVED_ENABLED=//p' "$ARCHIVE_ENV")"
assert_eq "disable leaves raw uploader active" active "$(cat "$ARCHIVE_ACTIVE")"
restarts="$(wc -l <"$ARCHIVE_SYSTEMCTL_LOG")"
run_step_fn 95-archive-derived.sh do_uninstall >/dev/null
assert_eq "repeated disable does not restart" "$restarts" "$(wc -l <"$ARCHIVE_SYSTEMCTL_LOG")"

# Restart failure must restore the exact pre-change file, including metadata.
cp "$ARCHIVE_ENV" "$TMP/archive-disabled"
archive_mode="$(stat -c '%a' "$ARCHIVE_ENV")"
archive_owner="$(stat -c '%u:%g' "$ARCHIVE_ENV")"
archive_bytes="$(sha256sum "$ARCHIVE_ENV")"
restarts="$(wc -l <"$ARCHIVE_SYSTEMCTL_LOG")"
export FM_ARCHIVE_RESTART_FAIL=1
out="$(run_step_fn 95-archive-derived.sh do_install && echo RC=0 || echo RC=1)"
unset FM_ARCHIVE_RESTART_FAIL
assert_contains "restart failure is reported" "RC=1" "$out"
assert_eq "restart failure restores bytes" "$archive_bytes" "$(sha256sum "$ARCHIVE_ENV")"
assert_eq "restart failure restores mode" "$archive_mode" "$(stat -c '%a' "$ARCHIVE_ENV")"
assert_eq "restart failure restores owner" "$archive_owner" "$(stat -c '%u:%g' "$ARCHIVE_ENV")"
assert_eq "restart failure attempts recovery" "$((restarts + 2))" "$(wc -l <"$ARCHIVE_SYSTEMCTL_LOG")"
assert_eq "secure temporary files are cleaned" false \
  "$(find "$TMP" -name '.fm-archive-derived.*' -print -quit | grep -q . && echo true || echo false)"

cp "$TMP/archive-disabled" "$ARCHIVE_ENV"
chmod 640 "$ARCHIVE_ENV"
assert_contains "readable credential file is refused" "RC=1" "$(run_step_fn 95-archive-derived.sh do_install && echo RC=0 || echo RC=1)"
chmod 600 "$ARCHIVE_ENV"
printf '\n  FM_ARCHIVE_UPLOADER_DERIVED_ENABLED=false\n' >>"$ARCHIVE_ENV"
assert_contains "duplicate derived flag is refused" "RC=1" "$(run_step_fn 95-archive-derived.sh do_install && echo RC=0 || echo RC=1)"
rm -f "$ARCHIVE_ENV"
ln -s "$TMP/archive-disabled" "$ARCHIVE_ENV"
assert_contains "symlinked env is refused" "RC=1" "$(run_step_fn 95-archive-derived.sh do_install && echo RC=0 || echo RC=1)"

# --- Result ----------------------------------------------------------------

echo
if [ "$FAIL" -eq 0 ]; then
  fm_ok "$PASS passed"
else
  fm_err "$FAIL failed, $PASS passed"
  exit 1
fi
