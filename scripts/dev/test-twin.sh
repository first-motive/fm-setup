#!/usr/bin/env bash
#
# test-twin.sh — exercise the twin step's install path.
#
#   ./scripts/dev/test-twin.sh
#
# The step builds a root-owned venv from a private repo the workspace's owner
# fetches, copies the OpenArm's and the Axol's descriptions out of the
# controllers image, and runs both as an account in no group. The cases are
# about what reaches root and what the unit says: only the pinned commit, every
# object checked; only plain files and directories from the image, each under
# its robot's own directory, listed before root extracts them; a unit naming
# the card's host and a URDF per robot, and reading the router from fm-comms'
# env; a robot twin that reads its instance's table flags from a file rendered
# from numbers only; a second run that changes nothing; a gate, not a
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

# The manifest's two robots: DIR, PATH in the image, TOP (the last component
# of PATH) and FILE (the URDF relative to DIR) of each. The OpenArm's TOP is its
# DIR; the Axol's is not. This parsing is the test's own fixture of the
# manifest's "robot|dir|path|urdf" format, not the step's parser, which the
# malformed-entry cases below exercise.
for entry in "${FM_TWIN_ROBOTS[@]}"; do
  case "$entry" in
    openarm\|*) IFS='|' read -r _ OA_DIR OA_PATH OA_FILE <<<"$entry" ;;
    axol\|*) IFS='|' read -r _ AX_DIR AX_PATH AX_FILE <<<"$entry" ;;
  esac
done
[ -n "${OA_DIR:-}" ] && [ -n "${AX_DIR:-}" ] || { fm_err "FM_TWIN_ROBOTS lacks openarm or axol"; exit 1; }
OA_URDF="$FM_TWIN_ROOT/description/$OA_DIR/$OA_FILE"
AX_URDF="$FM_TWIN_ROOT/description/$AX_DIR/$AX_FILE"
AX_TOP="${AX_PATH##*/}"

# Each description as `docker cp` streams it: one top directory, named after
# the last component of its path in the image.
DESC_PKG="$TMP/desc"
mkdir -p "$DESC_PKG/$OA_DIR/$(dirname "$OA_FILE")" "$DESC_PKG/$OA_DIR/cad" \
  "$DESC_PKG/$AX_TOP/$(dirname "$AX_FILE")" "$DESC_PKG/$AX_TOP/meshes"
printf '<robot name="openarm"/>\n' > "$DESC_PKG/$OA_DIR/$OA_FILE"
: > "$DESC_PKG/$OA_DIR/cad/link0.stl"
printf '<robot name="axol"/>\n' > "$DESC_PKG/$AX_TOP/$AX_FILE"
: > "$DESC_PKG/$AX_TOP/meshes/base.stl"
DESC_TAR="$TMP/desc.tar"
tar -C "$DESC_PKG" -cf "$DESC_TAR" "$OA_DIR"
AXOL_TAR="$TMP/axol.tar"
tar -C "$DESC_PKG" -cf "$AXOL_TAR" "$AX_TOP"

IMAGE="${FM_SIM_CONTROLLERS_IMAGE%:*}@$FM_SIM_CONTROLLERS_IMAGE_DIGEST_DEFAULT"

# --- Stand-ins ---------------------------------------------------------------

BIN="$TMP/bin"
mkdir -p "$BIN"
chmod 0755 "$BIN"
LOG="$TMP/calls.log"
: > "$LOG"
UV_TARBALL="$TMP/uv.tar.gz"

# stub NAME BODY — @LOG@, @TARBALL@, @DESC@, @AXOL@, @OAPATH@ and @AXPATH@ are
# baked in, because the step runs uv under `env -i` and a stand-in there sees no
# inherited variable.
stub() {
  local body="${2//@LOG@/$LOG}"
  body="${body//@TARBALL@/$UV_TARBALL}"
  body="${body//@DESC@/$DESC_TAR}"
  body="${body//@AXOL@/$AXOL_TAR}"
  body="${body//@OAPATH@/$OA_PATH}"
  body="${body//@AXPATH@/$AX_PATH}"
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
# list-units answers with the robot twin instances in FAKE_ROBOT_TWINS.
stub systemctl 'printf "systemctl %s\n" "$*" >> @LOG@
[ "$1" = is-active ] && exit 3
[ "$1" = list-units ] && { for u in ${FAKE_ROBOT_TWINS:-}; do echo "$u loaded active running fm-twin"; done; }
exit 0'
stub curl 'printf "curl %s\n" "$*" >> @LOG@
while [ $# -gt 0 ]; do [ "$1" = -o ] && { cp @TARBALL@ "$2"; exit 0; }; shift; done
exit 1'
stub getent 'grep -q "^useradd .*fm-twin$" @LOG@ && { echo "fm-twin:x:997:997::/nonexistent:/usr/sbin/nologin"; exit 0; }
exit 2'
# docker knows the images in FAKE_DOCKER_IMAGES and streams, for a `cp`, the
# OpenArm tarball (FAKE_DESC_TAR replaces it) or, for the Axol's path, the Axol
# tarball (FAKE_AXOL_TAR replaces it).
stub docker 'printf "docker %s\n" "$*" >> @LOG@
case "$1" in
  info) exit 0 ;;
  image)
    for ref in ${FAKE_DOCKER_IMAGES:-}; do [ "$ref" = "$3" ] && exit 0; done
    exit 1 ;;
  create) echo cid-1 ;;
  cp)
    case "$2" in
      cid-1:@AXPATH@) cat "${FAKE_AXOL_TAR:-@AXOL@}" ;;
      cid-1:@OAPATH@) cat "${FAKE_DESC_TAR:-@DESC@}" ;;
      *) exit 1 ;;
    esac ;;
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
  FM_TWIN_TEST_UV_SHA256="$UV_SHA" FM_TWIN_COMMIT="$PIN" FAKE_DOCKER_IMAGES="$IMAGE" \
  FAKE_ROBOT_TWINS="fm-twin-robot@fm-rob-02.service"
step() { env PATH="$BIN:$SYS_PATH" bash "$STEP" "$@" 2>&1; }
reset_host() { rm -rf "$R"; mkdir -p "$R/etc"; : > "$R/etc/fm-comms.env"; : > "$LOG"; }
count() { grep -c "$1" "$LOG" || true; }

TWIN="$R$FM_TWIN_ROOT"
UNIT="$R/etc/systemd/system/$FM_TWIN_UNIT"
ROBOT_ARGS="--robot openarm=$OA_URDF --robot axol=$AX_URDF"
EXEC="ExecStart=$FM_TWIN_ROOT/venv/bin/fm-twin run --source sim:fm-ws-01 $ROBOT_ARGS"
ROBOT_UNIT="$R/etc/systemd/system/$FM_TWIN_ROBOT_UNIT"
ROBOT_EXEC="ExecStart=$FM_TWIN_ROOT/venv/bin/fm-twin run --source \"robot:%i\" --profile axol --urdf $AX_URDF \$FM_TWIN_TABLE_ARGS"
TABLE="$R/etc/fm-twin/robot-fm-rob-02.env"
TABLE_ARGS="FM_TWIN_TABLE_ARGS=--table-z -0.607 --table-centre-xy 0.0 -0.32 --table-size-xy 1.2 0.4"

# step_tree NAME [ENTRY...] — a copy of the step and the files it sources under
# $TMP/tree-NAME, with FM_TWIN_ROBOTS replaced by the ENTRYs when any are
# given. Prints the copied step's path.
step_tree() {
  local t="$TMP/tree-$1"
  shift
  mkdir -p "$t/scripts/steps" "$t/scripts/internal"
  cp "$FM_ROOT/lib.sh" "$t/"
  cp "$FM_ROOT/scripts/manifest.sh" "$t/scripts/"
  cp "$FM_ROOT/scripts/internal/service-lib.sh" "$t/scripts/internal/"
  cp "$STEP" "$t/scripts/steps/"
  if [ $# -gt 0 ]; then
    { echo 'FM_TWIN_ROBOTS=('; printf '  %q\n' "$@"; echo ')'; } >> "$t/scripts/manifest.sh"
  fi
  printf '%s\n' "$t/scripts/steps/${STEP##*/}"
}

# tables_tree NAME [ENTRY...] — as step_tree, with FM_TWIN_ROBOT_TABLES replaced
# by the ENTRYs (none at all when none are given).
tables_tree() {
  local t="$TMP/tree-$1" name="$1"
  shift
  step_tree "$name" >/dev/null
  { echo 'FM_TWIN_ROBOT_TABLES=('; [ $# -eq 0 ] || printf '  %q\n' "$@"; echo ')'; } >> "$t/scripts/manifest.sh"
  printf '%s\n' "$t/scripts/steps/${STEP##*/}"
}

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
assert_has "the dry run prints the unit's command line" "$out" "$EXEC"
assert_has "  and the robot twin's" "$out" "$ROBOT_EXEC"
assert_has "  and copies each robot's description" "$out" "would copy   axol's $AX_PATH out of $IMAGE"
assert_has "  and writes each robot's table" "$out" "would write  /etc/fm-twin/robot-fm-rob-02.env"
assert_has "  with its flags" "$out" "$TABLE_ARGS"
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
assert_eq "the descriptions come from one container of the pinned controllers image" "1" \
  "$(count "^docker create $IMAGE$")"
assert_has "  the OpenArm's at its install share" "$(cat "$LOG")" "docker cp cid-1:$OA_PATH -"
assert_has "  the Axol's at its own" "$(cat "$LOG")" "docker cp cid-1:$AX_PATH -"
assert_eq "  and both land where the unit points" "true:true:true:true" \
  "$(exists "$R$OA_URDF"):$(exists "$TWIN/description/$OA_DIR/cad/link0.stl"):$(exists "$R$AX_URDF"):$(exists "$TWIN/description/$AX_DIR/meshes/base.stl")"
assert_eq "  the Axol's under $AX_DIR, not its archive's $AX_TOP/" "false" \
  "$(exists "$TWIN/description/$AX_TOP")"
unit="$(cat "$UNIT" 2>/dev/null || true)"
assert_has "the unit runs as the twin's account" "$unit" "User=fm-twin"
assert_has "the unit reads the router from fm-comms' env" "$unit" "EnvironmentFile=/etc/fm-comms.env"
assert_eq "the unit serves the card's host, with a URDF per robot" "$EXEC" "$(grep '^ExecStart=' "$UNIT" 2>/dev/null || true)"
assert_eq "the unit starts the twin again when it exits for another robot" "RestartForceExitStatus=75" \
  "$(grep '^RestartForceExitStatus=' "$UNIT" 2>/dev/null || true)"
assert_lacks "the unit names no router" "$unit" "--router"
assert_has "the unit restarts on failure" "$unit" "Restart=on-failure"
assert_has "the unit is bounded" "$unit" "MemoryMax=8G"
assert_has "the unit starts after the bridges" "$unit" "After=network-online.target $FM_COMMS_BRIDGE_UNIT $FM_COMMS_SIM_BRIDGE_UNIT"
assert_lacks "the unit carries no test root" "$unit" "$TMP"
assert_has "the twin is enabled" "$(cat "$LOG")" "systemctl enable $FM_TWIN_UNIT"
assert_has "a changed install restarts it" "$(cat "$LOG")" "systemctl restart $FM_TWIN_UNIT"
robot_unit="$(cat "$ROBOT_UNIT" 2>/dev/null || true)"
assert_eq "the robot twin serves its instance as the Axol, with the Axol's URDF" "$ROBOT_EXEC" \
  "$(grep '^ExecStart=' "$ROBOT_UNIT" 2>/dev/null || true)"
assert_has "  as the twin's account" "$robot_unit" "User=fm-twin"
assert_has "  reading the router from fm-comms' env" "$robot_unit" "EnvironmentFile=/etc/fm-comms.env"
assert_has "  restarting on failure" "$robot_unit" "Restart=on-failure"
assert_has "  hardened as the sim twin is" "$robot_unit" "CapabilityBoundingSet="
assert_eq "  with the sim twin's sandbox, line for line" \
  "$(grep -E '^(Protect|Private|Restrict|NoNew|Lock|Memory|Tasks)' "$UNIT")" \
  "$(grep -E '^(Protect|Private|Restrict|NoNew|Lock|Memory|Tasks)' "$ROBOT_UNIT")"
assert_lacks "  and no [Install] section, so it cannot be enabled" "$robot_unit" "[Install]"
assert_has "  reading its instance's table, if the robot has one" "$robot_unit" \
  "EnvironmentFile=-/etc/fm-twin/robot-%i.env"
assert_eq "the robot's table carries its --table-* flags" "$TABLE_ARGS" \
  "$(grep -v '^#' "$TABLE" 2>/dev/null || true)"
assert_eq "  root-owned, world-readable" "644" "$(stat -c %a "$TABLE" 2>/dev/null || true)"
assert_eq "  and is the only one" "robot-fm-rob-02.env" "$(ls "$R/etc/fm-twin" 2>/dev/null || true)"
assert_lacks "  carrying no test root" "$(cat "$TABLE" 2>/dev/null || true)" "$TMP"
assert_lacks "the robot twin is never enabled" "$(cat "$LOG")" "systemctl enable fm-twin-robot"
assert_has "a changed install restarts the robot twins systemd has loaded, by name" "$(cat "$LOG")" \
  "systemctl try-restart fm-twin-robot@fm-rob-02.service"

fm_log "a second install"
: > "$LOG"
rc=0; out="$(step install)" || rc=$?
assert_eq "it succeeds" "0" "$rc"
assert_eq "it fetches nothing" "0:0" "$(count '^curl '):$(count 'fetch ')"
assert_eq "it builds nothing" "0" "$(count '^uv sync')"
assert_eq "it copies nothing from the image" "0" "$(count '^docker create')"
assert_eq "it starts rather than restarts" "1:0" "$(count "^systemctl start $FM_TWIN_UNIT"):$(count '^systemctl restart')"
assert_eq "it restarts no robot twin" "0" "$(count '^systemctl try-restart')"
assert_has "it finds the table current" "$out" "/etc/fm-twin/robot-fm-rob-02.env current"

fm_log "a robot's table that changes"
moved_step="$(tables_tree moved "fm-rob-02|-0.55|0.1|-0.3|1.0|0.5")"
: > "$LOG"
rc=0; out="$(env PATH="$BIN:$SYS_PATH" bash "$moved_step" install 2>&1)" || rc=$?
assert_eq "install succeeds" "0" "$rc"
assert_eq "the table file carries the new flags" \
  "FM_TWIN_TABLE_ARGS=--table-z -0.55 --table-centre-xy 0.1 -0.3 --table-size-xy 1.0 0.5" \
  "$(grep -v '^#' "$TABLE" 2>/dev/null || true)"
assert_eq "the robot twin unit is left as it was" "0" "$(count "^sudo install .*$FM_TWIN_ROBOT_UNIT")"
assert_has "the running robot twins restart to read it" "$(cat "$LOG")" \
  "systemctl try-restart fm-twin-robot@fm-rob-02.service"
assert_eq "  and the sim twin does not" "0" "$(count "^systemctl restart $FM_TWIN_UNIT")"

fm_log "a robot whose entry goes"
none_step="$(tables_tree none)"
: > "$LOG"
: > "$R/etc/fm-twin/robot-fm-rob-09.env"
rc=0; out="$(env PATH="$BIN:$SYS_PATH" bash "$none_step" check 2>&1)" || rc=$?
assert_has "check names the table files no entry names" "$out" "no FM_TWIN_ROBOT_TABLES entry names"
rc=0; out="$(env PATH="$BIN:$SYS_PATH" bash "$none_step" install 2>&1)" || rc=$?
assert_eq "install succeeds" "0" "$rc"
assert_eq "it removes every table file" "" "$(ls "$R/etc/fm-twin" 2>/dev/null || true)"
assert_has "  and restarts the running robot twins, which then look for no table" "$(cat "$LOG")" \
  "systemctl try-restart fm-twin-robot@fm-rob-02.service"
assert_eq "the robot twin's unit still reads the optional file" "$ROBOT_EXEC" \
  "$(grep '^ExecStart=' "$ROBOT_UNIT" 2>/dev/null || true)"
step install >/dev/null

fm_log "a malformed table entry"
n=0
for bad in "fm-rob-02|-0.607|0.0|-0.32|1.2" \
           "fm-rob-02|-0.607|0.0|-0.32|1.2|0.4|9" \
           "fm-rob-02|z|0.0|-0.32|1.2|0.4" \
           "fm-rob-02|1e3|0.0|-0.32|1.2|0.4" \
           "fm-rob-02|-0.607|0.0|-0.32 --router x|1.2|0.4" \
           'fm-rob-02|-0.607|$X|-0.32|1.2|0.4' \
           "fm-rob-02|-0.607|0.0|-0.32|-1.2|0.4" \
           "fm-rob-02|.5|0.0|-0.32|1.2|0.4" \
           "fm-ws-01|-0.607|0.0|-0.32|1.2|0.4" \
           "../x|-0.607|0.0|-0.32|1.2|0.4"; do
  n=$((n + 1))
  bad_step="$(tables_tree "badtable$n" "$bad")"
  reset_host
  rc=0; out="$(env PATH="$BIN:$SYS_PATH" bash "$bad_step" install 2>&1)" || rc=$?
  assert_eq "$bad: install fails" "1" "$rc"
  assert_has "  it names the entry" "$out" "FM_TWIN_ROBOT_TABLES entry is malformed: '$bad'"
  assert_eq "  nothing is written" "false:false" "$(exists "$TWIN"):$(exists "$R/etc/fm-twin")"
done
rc=0; out="$(env PATH="$BIN:$SYS_PATH" bash "$bad_step" check 2>&1)" || rc=$?
assert_eq "check still exits 0 on the last malformed entry" "0" "$rc"
twice_step="$(tables_tree twice "fm-rob-02|-0.6|0|0|1|1" "fm-rob-02|-0.5|0|0|1|1")"
reset_host
rc=0; out="$(env PATH="$BIN:$SYS_PATH" bash "$twice_step" install 2>&1)" || rc=$?
assert_eq "a robot named twice fails" "1" "$rc"
assert_has "  and says so" "$out" "names fm-rob-02 twice"

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
mkdir -p "$OUTSIDE" "$TMP/evil1/$OA_DIR/urdf" "$TMP/evil2/$OA_DIR/urdf/out"
: > "$TMP/evil1/$OA_DIR/urdf/robot.urdf"
ln -s "$OUTSIDE" "$TMP/evil1/$OA_DIR/urdf/out"
: > "$TMP/evil2/$OA_DIR/urdf/out/planted"
tar -C "$TMP/evil1" -cf "$TMP/desc-link.tar" "$OA_DIR"
tar -C "$TMP/evil2" -rf "$TMP/desc-link.tar" "$OA_DIR/urdf/out/planted"
reset_host
rc=0; out="$(env FAKE_DESC_TAR="$TMP/desc-link.tar" PATH="$BIN:$SYS_PATH" bash "$STEP" install 2>&1)" || rc=$?
assert_eq "install refuses it" "1" "$rc"
assert_has "it names the entry" "$out" "not a plain file or directory: l"
assert_eq "nothing is written through the link" "false" "$(exists "$OUTSIDE/planted")"
assert_eq "no description and no unit" "false:false" "$(exists "$R$OA_URDF"):$(exists "$UNIT")"

fm_log "an entry outside the package"
mkdir -p "$TMP/evil3/other"
: > "$TMP/evil3/other/x"
tar -C "$DESC_PKG" -cf "$TMP/desc-outside.tar" "$OA_DIR"
tar -C "$TMP/evil3" -rf "$TMP/desc-outside.tar" other/x
reset_host
rc=0; out="$(env FAKE_DESC_TAR="$TMP/desc-outside.tar" PATH="$BIN:$SYS_PATH" bash "$STEP" install 2>&1)" || rc=$?
assert_eq "install refuses it" "1" "$rc"
assert_has "it names the entry" "$out" "outside $OA_DIR/: other/x"

fm_log "an Axol entry outside its archive's $AX_TOP/"
tar -C "$DESC_PKG" -cf "$TMP/axol-outside.tar" "$AX_TOP"
tar -C "$DESC_PKG" -rf "$TMP/axol-outside.tar" "$OA_DIR/$OA_FILE"
reset_host
rc=0; out="$(env FAKE_AXOL_TAR="$TMP/axol-outside.tar" PATH="$BIN:$SYS_PATH" bash "$STEP" install 2>&1)" || rc=$?
assert_eq "install refuses it" "1" "$rc"
assert_has "it names the entry" "$out" "outside $AX_TOP/: $OA_DIR"
assert_has "  and the robot" "$out" "the axol description in $IMAGE is refused"
assert_eq "no description moves into place and no unit is written" "false:false:false" \
  "$(exists "$R$OA_URDF"):$(exists "$R$AX_URDF"):$(exists "$UNIT")"
assert_eq "  and no staging directory is left behind" "" \
  "$(find "$TWIN" -maxdepth 1 -name '.description.*' 2>/dev/null)"

fm_log "a seal that fails part-way"
reset_host
step install >/dev/null
rm -f "$R$AX_URDF"
rc=0; out="$(env FAKE_FAIL="$TWIN/description/$AX_DIR" PATH="$BIN:$SYS_PATH" bash "$STEP" install 2>&1)" || rc=$?
assert_eq "install fails" "1" "$rc"
assert_eq "it leaves no marker and no staging directory" "false:" \
  "$(exists "$TWIN/description/.fm-image"):$(find "$TWIN" -maxdepth 1 -name '.description.*')"
rc=0; out="$(step install)" || rc=$?
assert_eq "the next run copies both again" "0:true:true" "$rc:$(exists "$R$OA_URDF"):$(exists "$R$AX_URDF")"

fm_log "no entry for the robot twin's profile"
OA_ENTRY="openarm|$OA_DIR|$OA_PATH|$OA_FILE"
sim_only_step="$(step_tree sim-only "$OA_ENTRY")"
reset_host
rc=0; out="$(env PATH="$BIN:$SYS_PATH" bash "$sim_only_step" install --dry-run 2>&1)" || rc=$?
assert_eq "the dry run succeeds" "0" "$rc"
assert_has "  and says there is no robot twin" "$out" "FM_TWIN_ROBOTS has no axol entry"
rc=0; out="$(env PATH="$BIN:$SYS_PATH" bash "$sim_only_step" install 2>&1)" || rc=$?
assert_eq "install succeeds" "0" "$rc"
assert_has "  and says why the robot twin is skipped" "$out" "installing the sim twin alone"
assert_eq "the sim twin is installed and the robot twin is not" "true:false" \
  "$(exists "$UNIT"):$(exists "$ROBOT_UNIT")"
assert_has "the sim twin is enabled" "$(cat "$LOG")" "systemctl enable $FM_TWIN_UNIT"
assert_eq "no robot twin is restarted" "0" "$(count '^systemctl try-restart')"
rc=0; out="$(env PATH="$BIN:$SYS_PATH" bash "$sim_only_step" check 2>&1)" || rc=$?
assert_eq "check exits 0" "0" "$rc"
assert_has "  and warns there is no robot twin" "$out" "FM_TWIN_ROBOTS has no axol entry"

fm_log "a malformed robot entry"
n=0
for bad in "axol|axol_description|/ws/x/urdf|../x.urdf" \
           "axol|axol_description|/ws/x/urdf|/etc/x.urdf" \
           "axol|..|/ws/x/urdf|x.urdf" \
           "axol|a/b|/ws/x/urdf|x.urdf" \
           "axol|axol_description|ws/x/urdf|x.urdf" \
           "Axol|axol_description|/ws/x/urdf|x.urdf"; do
  n=$((n + 1))
  bad_step="$(step_tree "bad$n" "$OA_ENTRY" "$bad")"
  reset_host
  rc=0; out="$(env PATH="$BIN:$SYS_PATH" bash "$bad_step" install 2>&1)" || rc=$?
  assert_eq "$bad: install fails" "1" "$rc"
  assert_has "  it names the entry" "$out" "FM_TWIN_ROBOTS entry is malformed: '$bad'"
  assert_eq "  no description and no unit" "false:false" "$(exists "$TWIN/description"):$(exists "$UNIT")"
done
rc=0; out="$(env PATH="$BIN:$SYS_PATH" bash "$bad_step" check 2>&1)" || rc=$?
assert_eq "check still exits 0 on the last malformed entry" "0" "$rc"

fm_log "robot_args"
args_step="$(step_tree args)"
sed '$d' "$args_step" > "${args_step%/*}/args.sh"
echo robot_args >> "${args_step%/*}/args.sh"
assert_eq "it renders one --robot word per robot" "$ROBOT_ARGS" \
  "$(env PATH="$BIN:$SYS_PATH" bash "${args_step%/*}/args.sh" 2>&1)"

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
assert_eq "no description and no unit" "false:false" "$(exists "$R$OA_URDF"):$(exists "$UNIT")"

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
assert_has "it finds the robot twin current" "$out" "$FM_TWIN_ROBOT_UNIT installed and current"
assert_has "it finds the robot's table current" "$out" \
  "fm-rob-02: /etc/fm-twin/robot-fm-rob-02.env current — --table-z -0.607"
assert_has "it finds the OpenArm's description current" "$out" "openarm: $OA_URDF is the description in $IMAGE"
assert_has "it finds the Axol's description current" "$out" "axol: $AX_URDF is the description in $IMAGE"
rm -f "$R$AX_URDF"
out="$(step check)"
assert_has "it finds a missing Axol URDF" "$out" "axol: $AX_URDF is not the description in $IMAGE"
assert_has "  and keeps the OpenArm's current" "$out" "openarm: $OA_URDF is the description in $IMAGE"

fm_log "uninstall"
rc=0; out="$(step uninstall)" || rc=$?
assert_eq "uninstall succeeds" "0" "$rc"
assert_eq "it removes the units, the tables and the tree" "false:false:false:false" \
  "$(exists "$UNIT"):$(exists "$ROBOT_UNIT"):$(exists "$R/etc/fm-twin"):$(exists "$TWIN")"
assert_has "it stops every robot twin first" "$(cat "$LOG")" "systemctl stop fm-twin-robot@fm-rob-02.service"
assert_has "it removes the account" "$(cat "$LOG")" "userdel fm-twin"

fm_log "uninstall with no robot twin loaded"
reset_host
step install >/dev/null
: > "$LOG"
rc=0; out="$(env FAKE_ROBOT_TWINS= PATH="$BIN:$SYS_PATH" bash "$STEP" uninstall 2>&1)" || rc=$?
assert_eq "uninstall succeeds" "0" "$rc"
assert_eq "it asks systemd to stop nothing" "0" "$(count '^systemctl stop')"
assert_eq "  and still removes the robot twin's unit" "false" "$(exists "$ROBOT_UNIT")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
