#!/usr/bin/env bash
#
# test-host-agent.sh — exercise the host-agent step's install path.
#
#   ./scripts/dev/test-host-agent.sh
#
# The step builds a root-owned venv whose code a root unit runs, and gives an
# unprivileged account one polkit right. The cases are about what reaches root
# and what the account holds: a uv only from a pinned, checksummed tarball;
# code copied out of this checkout, never run from it; an account in no group;
# a second run that changes nothing; and no "ready" after a privileged command
# fails.
#
# Every privileged tool the step calls — sudo, install, chown, useradd,
# userdel, systemctl, curl, uv — is a stand-in on PATH that records its argv.
# FAKE_FAIL=<text> makes sudo fail any command whose argv holds that text. The
# step's test hooks (FM_HOST_AGENT_TEST=1 with FM_HOST_AGENT_TEST_ROOT and
# FM_HOST_AGENT_TEST_UV_SHA256) point it at a temp root and a stand-in uv
# tarball. No root, daemon, or network is needed.
#
# No test framework, for the reason test-machine.sh gives.

# The stand-ins' bodies are single-quoted so they expand when they run.
# shellcheck disable=SC2016

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$_here/../.." && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$FM_ROOT/lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$FM_ROOT/scripts/manifest.sh"

[ "$(uname -s)" = "Linux" ] || { fm_warn "host-agent is a Linux step — skipping on $(uname -s)"; exit 0; }

STEP="$FM_ROOT/scripts/steps/93-host-agent.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP
unset FM_ROLE NONINTERACTIVE FAKE_FAIL
export FM_MACHINE_FILE="$TMP/machine.json"
printf '{"schema_version":1,"role":"workstation","name":"fm-ws-01"}\n' > "$FM_MACHINE_FILE"
R="$TMP/root"

PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); printf '    %s✓%s %s\n' "${FM_C_GREEN}" "${FM_C_RESET}" "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '    %s✗%s %s\n' "${FM_C_RED}" "${FM_C_RESET}" "$1"; }

assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"; printf '        expected: %s\n        actual:   %s\n' "$2" "$3"; fi
}
assert_has() {
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1"; printf '        missing: %s\n' "$3" ;; esac
}
assert_lacks() {
  case "$2" in *"$3"*) bad "$1"; printf '        found: %s\n' "$3" ;; *) ok "$1" ;; esac
}
exists() { [ -e "$1" ] && echo true || echo false; }

# --- Stand-ins ---------------------------------------------------------------

BIN="$TMP/bin"
mkdir -p "$BIN"
chmod 0755 "$BIN"
LOG="$TMP/calls.log"
: > "$LOG"
UV_TARBALL="$TMP/uv.tar.gz"

# stub NAME BODY — @LOG@ and @TARBALL@ are baked in, because the step runs uv
# under `env -i` and a stand-in there sees no inherited variable.
stub() {
  local body="${2//@LOG@/$LOG}"
  body="${body//@TARBALL@/$UV_TARBALL}"
  printf '#!/usr/bin/env bash\n%s\n' "$body" > "$BIN/$1"
  chmod 0755 "$BIN/$1"
}

# sudo drops its own flags, fails a command whose argv holds FAKE_FAIL, and
# otherwise runs the command as this account.
stub sudo 'printf "sudo %s\n" "$*" >> @LOG@
while [ $# -gt 0 ]; do case "$1" in -n) shift ;; -u) shift 2 ;; *) break ;; esac; done
if [ -n "${FAKE_FAIL:-}" ]; then case "$*" in *"$FAKE_FAIL"*) exit 1 ;; esac; fi
exec "$@"'
# install keeps everything but the ownership, which needs root.
stub install 'args=()
while [ $# -gt 0 ]; do case "$1" in -o|-g) shift 2 ;; *) args+=("$1"); shift ;; esac; done
exec /usr/bin/install "${args[@]}"'
for tool in chown useradd usermod userdel; do
  stub "$tool" "printf '$tool %s\n' \"\$*\" >> @LOG@"
done
stub systemctl 'printf "systemctl %s\n" "$*" >> @LOG@
[ "$1" = is-active ] && exit 3
exit 0'
stub curl 'printf "curl %s\n" "$*" >> @LOG@
while [ $# -gt 0 ]; do [ "$1" = -o ] && { cp @TARBALL@ "$2"; exit 0; }; shift; done
exit 1'
# getent knows the account once useradd has been called for it.
stub getent 'grep -q "^useradd .*fm-host$" @LOG@ && { echo "fm-host:x:998:998::/nonexistent:/usr/sbin/nologin"; exit 0; }
exit 2'

# The uv the step downloads: on `sync` it lays down both entrypoints.
ARCH="$(uname -m)"
mkdir -p "$TMP/uvpkg/uv-$ARCH-unknown-linux-gnu"
cat > "$TMP/uvpkg/uv-$ARCH-unknown-linux-gnu/uv" <<UV
#!/usr/bin/env bash
printf 'uv %s\n' "\$*" >> $LOG
env | sort | sed 's/^/uvenv /' >> $LOG
if [ "\$1" = sync ]; then
  mkdir -p "\$UV_PROJECT_ENVIRONMENT/bin"
  for name in fm-host-agent fm-host-disk-scan; do
    printf '#!/bin/sh\n' > "\$UV_PROJECT_ENVIRONMENT/bin/\$name"
    chmod +x "\$UV_PROJECT_ENVIRONMENT/bin/\$name"
  done
fi
UV
chmod 0755 "$TMP/uvpkg/uv-$ARCH-unknown-linux-gnu/uv"
tar -czf "$UV_TARBALL" -C "$TMP/uvpkg" "uv-$ARCH-unknown-linux-gnu"
UV_SHA="$(sha256sum "$UV_TARBALL" | cut -d' ' -f1)"

SYS_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export FM_HOST_AGENT_TEST=1 FM_HOST_AGENT_TEST_ROOT="$R" FM_HOST_AGENT_TEST_UV_SHA256="$UV_SHA"
step() { env PATH="$BIN:$SYS_PATH" bash "$STEP" "$@" 2>&1; }
reset_host() { rm -rf "$R"; mkdir -p "$R/etc/polkit-1/rules.d"; : > "$R/etc/fm-comms.env"; : > "$LOG"; }
count() { grep -c "$1" "$LOG" || true; }

AGENT="$R$FM_HOST_AGENT_ROOT"
UNIT="$R/etc/systemd/system/$FM_HOST_AGENT_UNIT"
SCAN_UNIT="$R/etc/systemd/system/$FM_HOST_DISK_SCAN_UNIT"
RULE="$R$FM_HOST_AGENT_POLKIT_RULE"

# --- Cases ---------------------------------------------------------------------

fm_log "the test hooks"
out="$(env FM_HOST_AGENT_TEST=0 PATH="$BIN:$SYS_PATH" bash "$STEP" check 2>&1 || true)"
assert_has "a test root without FM_HOST_AGENT_TEST=1 is refused" "$out" "needs FM_HOST_AGENT_TEST=1"
out="$(env FM_HOST_AGENT_TEST_ROOT=/etc PATH="$BIN:$SYS_PATH" bash "$STEP" check 2>&1 || true)"
assert_has "a test root outside the temp directory is refused" "$out" "must sit under"

fm_log "dry run"
reset_host
out="$(step install --dry-run)"
assert_has "the dry run prints the plan" "$out" "would build  $FM_HOST_AGENT_ROOT/venv"
assert_eq "the dry run writes nothing" "false" "$(exists "$AGENT")"
assert_eq "the dry run calls no privileged tool" "0" "$(count '^sudo ')"

fm_log "install"
reset_host
rc=0; out="$(step install)" || rc=$?
assert_eq "install succeeds" "0" "$rc"
assert_has "the account is a system account with no login and no home" "$(cat "$LOG")" \
  "useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin fm-host"
assert_eq "the account is put in no other group" "0" "$(count '^usermod ')"
assert_eq "the project is copied, tests left behind" "true:false" \
  "$(exists "$AGENT/project/src/fm_host_agent/load.py"):$(exists "$AGENT/project/tests")"
assert_eq "both entrypoints are built" "true:true" \
  "$(exists "$AGENT/venv/bin/fm-host-agent"):$(exists "$AGENT/venv/bin/fm-host-disk-scan")"
assert_has "the venv is built with nothing inherited" "$(cat "$LOG")" "uvenv UV_NO_CONFIG=1"
assert_has "the venv is frozen and non-editable" "$(cat "$LOG")" "sync --quiet --frozen --no-dev --no-editable"
assert_eq "the units and the rule are this checkout's" "same" \
  "$(cmp -s "$UNIT" "$FM_ROOT/host-agent/systemd/$FM_HOST_AGENT_UNIT" \
     && cmp -s "$SCAN_UNIT" "$FM_ROOT/host-agent/systemd/$FM_HOST_DISK_SCAN_UNIT" \
     && cmp -s "$RULE" "$FM_ROOT/host-agent/systemd/50-fm-host-agent.rules" && echo same)"
assert_eq "the state directory exists for the scan's report" "true" "$(exists "$R$FM_HOST_AGENT_STATE")"
assert_has "the agent is enabled" "$(cat "$LOG")" "systemctl enable $FM_HOST_AGENT_UNIT"
assert_has "a changed install restarts the agent" "$(cat "$LOG")" "systemctl restart $FM_HOST_AGENT_UNIT"
assert_has "the tree is handed to root on every run" "$(cat "$LOG")" "chown -R root:root $AGENT"
assert_lacks "the scan unit is never enabled — it runs on request" "$(cat "$LOG")" "enable $FM_HOST_DISK_SCAN_UNIT"

fm_log "a second install"
: > "$LOG"
rc=0; out="$(step install)" || rc=$?
assert_eq "it succeeds" "0" "$rc"
assert_eq "it fetches no uv" "0" "$(count '^curl ')"
assert_eq "it builds nothing" "0" "$(count '^uv sync')"
assert_eq "it starts rather than restarts" "1:0" "$(count "^systemctl start $FM_HOST_AGENT_UNIT"):$(count '^systemctl restart')"

fm_log "a uv that does not match its pin"
reset_host
rc=0; out="$(env FM_HOST_AGENT_TEST_UV_SHA256="$(printf '%064d' 0)" PATH="$BIN:$SYS_PATH" bash "$STEP" install 2>&1)" || rc=$?
assert_eq "install fails" "1" "$rc"
assert_has "it says why" "$out" "checksum mismatch"
assert_eq "no unit is written" "false" "$(exists "$UNIT")"

fm_log "a symlink in the source"
reset_host
FAKE_SRC="$TMP/src-with-link"
rm -rf "$FAKE_SRC"
tar -C "$FM_ROOT" --exclude=.git --exclude=.venv -cf - . | { mkdir -p "$FAKE_SRC"; tar -C "$FAKE_SRC" -xf -; }
ln -s /etc/hostname "$FAKE_SRC/host-agent/src/fm_host_agent/leak.py"
rc=0; out="$(env PATH="$BIN:$SYS_PATH" bash "$FAKE_SRC/scripts/steps/93-host-agent.sh" install 2>&1)" || rc=$?
assert_eq "install refuses it" "1" "$rc"
assert_has "it names the file" "$out" "src/fm_host_agent/leak.py is not a plain file"
assert_eq "nothing is copied" "false" "$(exists "$AGENT/project")"

fm_log "a privileged command that fails"
reset_host
rc=0; out="$(env FAKE_FAIL="$FM_HOST_AGENT_POLKIT_RULE" PATH="$BIN:$SYS_PATH" bash "$STEP" install 2>&1)" || rc=$?
assert_eq "install fails" "1" "$rc"
assert_lacks "it enables nothing" "$(cat "$LOG")" "systemctl enable"

fm_log "no fm-comms env yet"
reset_host
rm "$R/etc/fm-comms.env"
rc=0; out="$(step install)" || rc=$?
assert_eq "install stops at the gate and succeeds" "0" "$rc"
assert_has "it says what to do" "$out" "--only host-agent"
assert_lacks "it enables nothing" "$(cat "$LOG")" "systemctl enable"

fm_log "check"
reset_host
rc=0; out="$(step check)" || rc=$?
assert_eq "check exits 0 on a bare host" "0" "$rc"
assert_has "it reports the missing unit" "$out" "$FM_HOST_AGENT_UNIT missing or out of date"
step install >/dev/null
out="$(step check)"
assert_has "it finds the installed units current" "$out" "$FM_HOST_AGENT_UNIT installed and current"
# Under the stand-ins the tree belongs to this account, not root, which is the case to flag.
if [ "$(id -u)" != 0 ]; then
  assert_has "it flags a tree root does not own alone" "$out" "is not root-owned or is writable by others"
else
  assert_has "it finds the tree root's alone" "$out" "$FM_HOST_AGENT_ROOT is root's alone"
fi

fm_log "uninstall"
rc=0; out="$(step uninstall)" || rc=$?
assert_eq "uninstall succeeds" "0" "$rc"
assert_eq "it removes the units, the rule and the tree" "false:false:false:false" \
  "$(exists "$UNIT"):$(exists "$SCAN_UNIT"):$(exists "$RULE"):$(exists "$AGENT")"
assert_has "it removes the account" "$(cat "$LOG")" "userdel fm-host"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
