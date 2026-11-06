#!/usr/bin/env bash
#
# test-twin.sh — exercise the twin step's install path.
#
#   ./scripts/dev/test-twin.sh
#
# The step builds a root-owned venv from a private repo the workspace's owner
# fetches, copies the OpenArm description out of the controllers image, and
# runs both as an account in no group. The cases are about what reaches root
# and what the unit says: only the pinned commit, every object checked; only
# plain files and directories from the image, listed before root extracts
# them; a unit naming the card's host and reading the
# router from fm-comms' env; a second run that changes nothing; a gate, not a
# failure, where a person has something to do; and no "running" after a
# privileged command fails.
#
# Every privileged tool the step calls — sudo, install, chown, useradd,
# userdel, systemctl, curl, docker, uv — is a stand-in on PATH that records its
# argv. FAKE_FAIL=<text> makes sudo fail any command whose argv holds that text.
# The step's test hooks (FM_TWIN_TEST=1 with FM_TWIN_TEST_ROOT,
# FM_TWIN_TEST_SOURCE and FM_TWIN_TEST_UV_SHA256) point it at a temp root, a
# local fm-twin repository and a stand-in uv tarball. No root, daemon, or
# network is needed.
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

[ "$(uname -s)" = "Linux" ] || { fm_warn "twin is a Linux step — skipping on $(uname -s)"; exit 0; }
fm_require_cmd jq || exit 1

STEP="$FM_ROOT/scripts/steps/94-twin.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP
unset FM_ROLE NONINTERACTIVE FAKE_FAIL FM_TWIN_COMMIT FM_SIM_CONTROLLERS_IMAGE_DIGEST
export FM_MACHINE_FILE="$TMP/machine.json"
export FM_HOME="$TMP/ws"
mkdir -p "$FM_HOME"
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

# --- Upstream ------------------------------------------------------------------

# A stand-in fm-twin: the files the venv is built from, and a test tree that
# must stay behind.
UPSTREAM="$TMP/fm-twin"
git init --quiet "$UPSTREAM"
git -C "$UPSTREAM" config uploadpack.allowAnySHA1InWant true
mkdir -p "$UPSTREAM/src/fm_twin" "$UPSTREAM/tests"
printf '[project]\nname = "fm-twin"\n' > "$UPSTREAM/pyproject.toml"
: > "$UPSTREAM/uv.lock"
: > "$UPSTREAM/README.md"
: > "$UPSTREAM/src/fm_twin/__init__.py"
: > "$UPSTREAM/tests/test_x.py"
git -C "$UPSTREAM" add -A
git -C "$UPSTREAM" -c user.name=t -c user.email=t@t commit --quiet -m init
PIN="$(git -C "$UPSTREAM" rev-parse HEAD)"
# A second commit, for an owner who hands root something other than the pin.
echo changed > "$UPSTREAM/README.md"
git -C "$UPSTREAM" -c user.name=t -c user.email=t@t commit --quiet -am other
OTHER="$(git -C "$UPSTREAM" rev-parse HEAD)"

# The description package as `docker cp` streams it: one top directory.
DESC_PKG="$TMP/desc"
mkdir -p "$DESC_PKG/$FM_TWIN_DESCRIPTION_PACKAGE/urdf" "$DESC_PKG/$FM_TWIN_DESCRIPTION_PACKAGE/cad"
printf '<robot name="openarm"/>\n' > "$DESC_PKG/$FM_TWIN_DESCRIPTION_PACKAGE/urdf/robot.urdf"
: > "$DESC_PKG/$FM_TWIN_DESCRIPTION_PACKAGE/cad/link0.stl"
DESC_TAR="$TMP/desc.tar"
tar -C "$DESC_PKG" -cf "$DESC_TAR" "$FM_TWIN_DESCRIPTION_PACKAGE"

IMAGE="${FM_SIM_CONTROLLERS_IMAGE%:*}@$FM_SIM_CONTROLLERS_IMAGE_DIGEST_DEFAULT"

# --- Stand-ins ---------------------------------------------------------------

BIN="$TMP/bin"
mkdir -p "$BIN"
chmod 0755 "$BIN"
LOG="$TMP/calls.log"
: > "$LOG"
UV_TARBALL="$TMP/uv.tar.gz"

# stub NAME BODY — @LOG@, @TARBALL@ and @DESC@ are baked in, because the step
# runs uv under `env -i` and a stand-in there sees no inherited variable.
stub() {
  local body="${2//@LOG@/$LOG}"
  body="${body//@TARBALL@/$UV_TARBALL}"
  body="${body//@DESC@/$DESC_TAR}"
  printf '#!/usr/bin/env bash\n%s\n' "$body" > "$BIN/$1"
  chmod 0755 "$BIN/$1"
}

stub sudo 'printf "sudo %s\n" "$*" >> @LOG@
while [ $# -gt 0 ]; do case "$1" in -n) shift ;; -u) shift 2 ;; *) break ;; esac; done
if [ -n "${FAKE_FAIL:-}" ]; then case "$*" in *"$FAKE_FAIL"*) exit 1 ;; esac; fi
exec "$@"'
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
stub getent 'grep -q "^useradd .*fm-twin$" @LOG@ && { echo "fm-twin:x:997:997::/nonexistent:/usr/sbin/nologin"; exit 0; }
exit 2'
# docker knows the images in FAKE_DOCKER_IMAGES and streams the description
# tarball for any `cp`.
stub docker 'printf "docker %s\n" "$*" >> @LOG@
case "$1" in
  info) exit 0 ;;
  image)
    for ref in ${FAKE_DOCKER_IMAGES:-}; do [ "$ref" = "$3" ] && exit 0; done
    exit 1 ;;
  create) echo cid-1 ;;
  cp) cat "${FAKE_DESC_TAR:-@DESC@}" ;;
  rm) exit 0 ;;
  *) exit 1 ;;
esac'

# git, as the workspace's owner runs it: the real one, except that with
# FAKE_SWAP_PIN set the owner's ref is moved to that commit before the bundle is
# written, as a hostile owner could. Root's git runs under `env -i` with
# PATH=/usr/bin:/bin and never sees this stand-in.
REAL_GIT="$(command -v git)"
cat > "$BIN/git" <<GIT
#!/usr/bin/env bash
if [ -n "\${FAKE_SWAP_PIN:-}" ] && [ "\$2" = bundle ]; then
  $REAL_GIT "\$1" fetch --quiet "\$FM_TWIN_TEST_SOURCE" "+\$FAKE_SWAP_PIN:refs/fm/pin" || exit 1
fi
if [ -n "\${FAKE_BUNDLE_LINK:-}" ] && [ "\$2" = bundle ]; then
  $REAL_GIT "\$@" || exit 1
  bundle="\${*: -2:1}"
  rm -f "\$bundle" && ln -s "\$FAKE_BUNDLE_LINK" "\$bundle"
  exit 0
fi
exec $REAL_GIT "\$@"
GIT
chmod 0755 "$BIN/git"

ARCH="$(uname -m)"
mkdir -p "$TMP/uvpkg/uv-$ARCH-unknown-linux-gnu"
cat > "$TMP/uvpkg/uv-$ARCH-unknown-linux-gnu/uv" <<UV
#!/usr/bin/env bash
printf 'uv %s\n' "\$*" >> $LOG
env | sort | sed 's/^/uvenv /' >> $LOG
if [ "\$1" = sync ]; then
  mkdir -p "\$UV_PROJECT_ENVIRONMENT/bin"
  printf '#!/bin/sh\n' > "\$UV_PROJECT_ENVIRONMENT/bin/fm-twin"
  chmod +x "\$UV_PROJECT_ENVIRONMENT/bin/fm-twin"
fi
UV
chmod 0755 "$TMP/uvpkg/uv-$ARCH-unknown-linux-gnu/uv"
tar -czf "$UV_TARBALL" -C "$TMP/uvpkg" "uv-$ARCH-unknown-linux-gnu"
UV_SHA="$(sha256sum "$UV_TARBALL" | cut -d' ' -f1)"

SYS_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export FM_TWIN_TEST=1 FM_TWIN_TEST_ROOT="$R" FM_TWIN_TEST_SOURCE="file://$UPSTREAM" \
  FM_TWIN_TEST_UV_SHA256="$UV_SHA" FM_TWIN_COMMIT="$PIN" FAKE_DOCKER_IMAGES="$IMAGE"
step() { env PATH="$BIN:$SYS_PATH" bash "$STEP" "$@" 2>&1; }
reset_host() { rm -rf "$R"; mkdir -p "$R/etc"; : > "$R/etc/fm-comms.env"; : > "$LOG"; }
count() { grep -c "$1" "$LOG" || true; }

TWIN="$R$FM_TWIN_ROOT"
UNIT="$R/etc/systemd/system/$FM_TWIN_UNIT"
URDF="$FM_TWIN_ROOT/description/$FM_TWIN_DESCRIPTION_PACKAGE/urdf/robot.urdf"

# --- Cases ---------------------------------------------------------------------

fm_log "the test hooks"
out="$(env FM_TWIN_TEST=0 PATH="$BIN:$SYS_PATH" bash "$STEP" check 2>&1 || true)"
assert_has "a test root without FM_TWIN_TEST=1 is refused" "$out" "needs FM_TWIN_TEST=1"
out="$(env FM_TWIN_TEST_ROOT=/etc PATH="$BIN:$SYS_PATH" bash "$STEP" check 2>&1 || true)"
assert_has "a test root outside the temp directory is refused" "$out" "must sit under"
out="$(env -u FM_TWIN_TEST_ROOT PATH="$BIN:$SYS_PATH" bash "$STEP" check 2>&1 || true)"
assert_has "a test source without a test root is refused" "$out" "need FM_TWIN_TEST_ROOT"

fm_log "dry run"
reset_host
out="$(step install --dry-run)"
assert_has "the dry run prints the unit's command line" "$out" \
  "ExecStart=$FM_TWIN_ROOT/venv/bin/fm-twin run --source sim:fm-ws-01 --urdf $URDF"
assert_eq "the dry run writes nothing" "false" "$(exists "$TWIN")"
assert_eq "the dry run calls no privileged tool" "0" "$(count '^sudo ')"

fm_log "install"
reset_host
rc=0; out="$(step install)" || rc=$?
assert_eq "install succeeds" "0" "$rc"
assert_has "the account is a system account with no login and no home" "$(cat "$LOG")" \
  "useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin fm-twin"
assert_eq "the account is put in no group" "0" "$(count '^usermod ')"
assert_eq "root's repository holds the pin" "$PIN" \
  "$(git --git-dir="$TWIN/src.git" rev-parse "refs/fm/$PIN" 2>/dev/null)"
assert_eq "the project is copied, tests left behind" "true:false" \
  "$(exists "$TWIN/project/src/fm_twin/__init__.py"):$(exists "$TWIN/project/tests")"
assert_eq "the entrypoint is built" "true" "$(exists "$TWIN/venv/bin/fm-twin")"
assert_has "the venv is built with nothing inherited" "$(cat "$LOG")" "uvenv UV_NO_CONFIG=1"
assert_has "the venv is frozen and non-editable" "$(cat "$LOG")" "sync --quiet --frozen --no-dev --no-editable"
assert_has "the description comes from the pinned controllers image" "$(cat "$LOG")" "docker create $IMAGE"
assert_has "  at its install share" "$(cat "$LOG")" "docker cp cid-1:$FM_TWIN_DESCRIPTION_IN_IMAGE -"
assert_eq "  and lands where the unit points" "true:true" \
  "$(exists "$R$URDF"):$(exists "$TWIN/description/$FM_TWIN_DESCRIPTION_PACKAGE/cad/link0.stl")"
unit="$(cat "$UNIT" 2>/dev/null || true)"
assert_has "the unit runs as the twin's account" "$unit" "User=fm-twin"
assert_has "the unit reads the router from fm-comms' env" "$unit" "EnvironmentFile=/etc/fm-comms.env"
assert_has "the unit serves the card's host" "$unit" "--source sim:fm-ws-01 --urdf $URDF"
assert_lacks "the unit names no router" "$unit" "--router"
assert_has "the unit restarts on failure" "$unit" "Restart=on-failure"
assert_has "the unit is bounded" "$unit" "MemoryMax=8G"
assert_has "the unit starts after the bridges" "$unit" "After=network-online.target $FM_COMMS_BRIDGE_UNIT $FM_COMMS_SIM_BRIDGE_UNIT"
assert_lacks "the unit carries no test root" "$unit" "$TMP"
assert_has "the twin is enabled" "$(cat "$LOG")" "systemctl enable $FM_TWIN_UNIT"
assert_has "a changed install restarts it" "$(cat "$LOG")" "systemctl restart $FM_TWIN_UNIT"

fm_log "a second install"
: > "$LOG"
rc=0; out="$(step install)" || rc=$?
assert_eq "it succeeds" "0" "$rc"
assert_eq "it fetches nothing" "0:0" "$(count '^curl '):$(count 'fetch ')"
assert_eq "it builds nothing" "0" "$(count '^uv sync')"
assert_eq "it copies nothing from the image" "0" "$(count '^docker create')"
assert_eq "it starts rather than restarts" "1:0" "$(count "^systemctl start $FM_TWIN_UNIT"):$(count '^systemctl restart')"

fm_log "a pin the source does not hold"
reset_host
rc=0; out="$(env FM_TWIN_COMMIT="$(printf 'a%.0s' $(seq 40))" PATH="$BIN:$SYS_PATH" bash "$STEP" install 2>&1)" || rc=$?
assert_eq "install stops at the gate and succeeds" "0" "$rc"
assert_has "it names the credential to add" "$out" "gh auth login"
assert_eq "no unit is written" "false" "$(exists "$UNIT")"

fm_log "a malformed pin"
reset_host
rc=0; out="$(env FM_TWIN_COMMIT=main PATH="$BIN:$SYS_PATH" bash "$STEP" install 2>&1)" || rc=$?
assert_eq "install fails" "1" "$rc"
assert_has "it says why" "$out" "FM_TWIN_COMMIT is malformed"

fm_log "no controllers image pulled"
reset_host
rc=0; out="$(env FAKE_DOCKER_IMAGES= PATH="$BIN:$SYS_PATH" bash "$STEP" install 2>&1)" || rc=$?
assert_eq "install stops at the gate and succeeds" "0" "$rc"
assert_has "it names the command that pulls it" "$out" "FM_SIM_CONTROLLERS=1 ./install.sh"
assert_eq "it changes nothing" "false:0" "$(exists "$TWIN"):$(count '^sudo ')"

fm_log "a link in the image's description"
# A symlink entry, then a file through it: extracted, root would write outside.
OUTSIDE="$TMP/outside"
mkdir -p "$OUTSIDE" "$TMP/evil1/$FM_TWIN_DESCRIPTION_PACKAGE/urdf" "$TMP/evil2/$FM_TWIN_DESCRIPTION_PACKAGE/urdf/out"
: > "$TMP/evil1/$FM_TWIN_DESCRIPTION_PACKAGE/urdf/robot.urdf"
ln -s "$OUTSIDE" "$TMP/evil1/$FM_TWIN_DESCRIPTION_PACKAGE/urdf/out"
: > "$TMP/evil2/$FM_TWIN_DESCRIPTION_PACKAGE/urdf/out/planted"
tar -C "$TMP/evil1" -cf "$TMP/desc-link.tar" "$FM_TWIN_DESCRIPTION_PACKAGE"
tar -C "$TMP/evil2" -rf "$TMP/desc-link.tar" "$FM_TWIN_DESCRIPTION_PACKAGE/urdf/out/planted"
reset_host
rc=0; out="$(env FAKE_DESC_TAR="$TMP/desc-link.tar" PATH="$BIN:$SYS_PATH" bash "$STEP" install 2>&1)" || rc=$?
assert_eq "install refuses it" "1" "$rc"
assert_has "it names the entry" "$out" "not a plain file or directory: l"
assert_eq "nothing is written through the link" "false" "$(exists "$OUTSIDE/planted")"
assert_eq "no description and no unit" "false:false" "$(exists "$R$URDF"):$(exists "$UNIT")"

fm_log "an entry outside the package"
mkdir -p "$TMP/evil3/other"
: > "$TMP/evil3/other/x"
tar -C "$DESC_PKG" -cf "$TMP/desc-outside.tar" "$FM_TWIN_DESCRIPTION_PACKAGE"
tar -C "$TMP/evil3" -rf "$TMP/desc-outside.tar" other/x
reset_host
rc=0; out="$(env FAKE_DESC_TAR="$TMP/desc-outside.tar" PATH="$BIN:$SYS_PATH" bash "$STEP" install 2>&1)" || rc=$?
assert_eq "install refuses it" "1" "$rc"
assert_has "it names the entry" "$out" "outside $FM_TWIN_DESCRIPTION_PACKAGE/: other/x"

fm_log "an owner who hands root another commit"
reset_host
rc=0; out="$(env FAKE_SWAP_PIN="$OTHER" PATH="$BIN:$SYS_PATH" bash "$STEP" install 2>&1)" || rc=$?
assert_eq "install fails" "1" "$rc"
assert_has "it names the commit it got" "$out" "the fetched commit is '$OTHER', not the pinned $PIN"
assert_eq "root's repository keeps no ref to it" "" \
  "$(git --git-dir="$TWIN/src.git" for-each-ref refs/fm 2>/dev/null)"
assert_eq "no project and no unit" "false:false" "$(exists "$TWIN/project"):$(exists "$UNIT")"

fm_log "an owner whose bundle is a link"
reset_host
rc=0; out="$(env FAKE_BUNDLE_LINK=/etc/hostname PATH="$BIN:$SYS_PATH" bash "$STEP" install 2>&1)" || rc=$?
assert_eq "install fails" "1" "$rc"
assert_has "it refuses root's copy of it" "$out" "pin.bundle is not a plain file"
assert_eq "no project and no unit" "false:false" "$(exists "$TWIN/project"):$(exists "$UNIT")"

fm_log "an image that streams no tar"
printf 'not a tar\n' > "$TMP/desc-garbage.tar"
reset_host
rc=0; out="$(env FAKE_DESC_TAR="$TMP/desc-garbage.tar" PATH="$BIN:$SYS_PATH" bash "$STEP" install 2>&1)" || rc=$?
assert_eq "install fails" "1" "$rc"
assert_has "it says why" "$out" "is not a readable tar"
assert_eq "no description and no unit" "false:false" "$(exists "$R$URDF"):$(exists "$UNIT")"

fm_log "no uv pin"
assert_eq "an empty pin is never a current uv" "1" \
  "$(bash -c ". '$FM_ROOT/lib.sh'; . '$FM_ROOT/scripts/internal/service-lib.sh'; svc_uv_current '' /nonexistent ''; echo \$?")"
assert_eq "an empty pin installs nothing" "1" \
  "$(bash -c ". '$FM_ROOT/lib.sh'; . '$FM_ROOT/scripts/manifest.sh'; . '$FM_ROOT/scripts/internal/service-lib.sh'; svc_install_uv '' /nonexistent '' 2>/dev/null; echo \$?")"

fm_log "a malformed controllers image digest"
reset_host
rc=0; out="$(env FM_SIM_CONTROLLERS_IMAGE_DIGEST=sha256:nope PATH="$BIN:$SYS_PATH" bash "$STEP" install 2>&1)" || rc=$?
assert_eq "install fails" "1" "$rc"
assert_has "it says why" "$out" "FM_SIM_CONTROLLERS_IMAGE_DIGEST is malformed"
assert_eq "it changes nothing" "false:0" "$(exists "$TWIN"):$(count '^sudo ')"

fm_log "a uv that does not match its pin"
reset_host
rc=0; out="$(env FM_TWIN_TEST_UV_SHA256="$(printf '%064d' 0)" PATH="$BIN:$SYS_PATH" bash "$STEP" install 2>&1)" || rc=$?
assert_eq "install fails" "1" "$rc"
assert_has "it says why" "$out" "checksum mismatch"
assert_eq "no unit is written" "false" "$(exists "$UNIT")"

fm_log "a privileged command that fails"
reset_host
rc=0; out="$(env FAKE_FAIL="systemctl daemon-reload" PATH="$BIN:$SYS_PATH" bash "$STEP" install 2>&1)" || rc=$?
assert_eq "install fails" "1" "$rc"
assert_has "it says which" "$out" "reloading systemd failed"
assert_lacks "it enables nothing" "$(cat "$LOG")" "systemctl enable"

fm_log "no fm-comms env yet"
reset_host
rm "$R/etc/fm-comms.env"
rc=0; out="$(step install)" || rc=$?
assert_eq "install stops at the gate and succeeds" "0" "$rc"
assert_has "it says what to do" "$out" "--only twin"
assert_lacks "it enables nothing" "$(cat "$LOG")" "systemctl enable"

fm_log "check"
reset_host
rc=0; out="$(step check)" || rc=$?
assert_eq "check exits 0 on a bare host" "0" "$rc"
assert_has "it reports the missing unit" "$out" "$FM_TWIN_UNIT missing or out of date"
step install >/dev/null
out="$(step check)"
assert_has "it finds the installed unit current" "$out" "$FM_TWIN_UNIT installed and current — serves sim:fm-ws-01"
assert_has "it finds the description current" "$out" "$URDF is the description in $IMAGE"

fm_log "uninstall"
rc=0; out="$(step uninstall)" || rc=$?
assert_eq "uninstall succeeds" "0" "$rc"
assert_eq "it removes the unit and the tree" "false:false" "$(exists "$UNIT"):$(exists "$TWIN")"
assert_has "it removes the account" "$(cat "$LOG")" "userdel fm-twin"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
