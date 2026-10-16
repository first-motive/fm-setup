#!/usr/bin/env bash
#
# test-sim.sh — exercise the sim workload: the card value, the shared helpers,
# the sim-lib checks, the install path, and the Isaac preflight.
#
#   ./scripts/dev/test-sim.sh
#
# The sim step installs a service that runs with docker rights, so the cases are
# about what reaches that service and what root runs to build it: code only from
# a commit root fetched itself, never from the workspace's .git; a uv only from
# a pinned, checksummed tarball; a unit only from a template that passes the
# allowlist; no grant or enable without a pinned digest and a person's yes; and
# no "ready" after a privileged command fails.
#
# Every privileged tool the step calls — sudo, install, chown, useradd, usermod,
# userdel, systemctl, curl, uv, docker, nvidia-smi — is a stand-in on PATH that
# records its argv. FAKE_FAIL=<text> makes sudo fail any command whose argv
# holds that text, so each privileged call site can be failed on its own. The step's
# test hooks (FM_SIM_TEST=1 with FM_SIM_TEST_ROOT, FM_SIM_TEST_SOURCE and
# FM_SIM_TEST_UV_SHA256) point it at a temp root, a local upstream repository,
# and a stand-in uv tarball. No root, daemon, GPU, or network is needed.
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
# shellcheck source=../internal/sim-lib.sh disable=SC1091
. "$FM_ROOT/scripts/internal/sim-lib.sh"

[ "$(uname -s)" = "Linux" ] || { fm_warn "sim is a Linux step — skipping on $(uname -s)"; exit 0; }
fm_require_cmd jq
fm_require_cmd git

STEP="$FM_ROOT/scripts/steps/91-sim.sh"
ISAAC_STEP="$FM_ROOT/scripts/steps/90-isaac-sim.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP
unset FM_HOME FM_SIM_IMAGE_DIGEST FM_SIM_COMMIT NONINTERACTIVE FAKE_FAIL
export FM_MACHINE_FILE="$TMP/machine.json"
R="$TMP/root"
WS="$TMP/ws"
UPSTREAM="$TMP/upstream"
mkdir -p "$WS" "$R"

PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); printf '    %s✓%s %s\n' "${FM_C_GREEN}" "${FM_C_RESET}" "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '    %s✗%s %s\n' "${FM_C_RED}" "${FM_C_RESET}" "$1"; }

assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"; printf '        expected: %s\n        actual:   %s\n' "$2" "$3"; fi
}
assert_rc() {
  local label="$1" want="$2" got=0; shift 2
  "$@" >/dev/null 2>&1 || got=$?
  assert_eq "$label" "$want" "$got"
}
assert_has() {
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1"; printf '        missing: %s\n' "$3" ;; esac
}
assert_lacks() {
  case "$2" in *"$3"*) bad "$1"; printf '        found: %s\n' "$3" ;; *) ok "$1" ;; esac
}
exists() { [ -e "$1" ] && echo true || echo false; }
count() { grep -c "$1" "$SIM_LOG" || true; }

card() {  # workload — "" for none
  if [ -n "$1" ]; then
    printf '{"role":"workstation","name":"fm-ws-01","workload":"%s","workspace":"%s"}\n' "$1" "$WS" > "$FM_MACHINE_FILE"
  else
    printf '{"role":"workstation","name":"fm-ws-01","workspace":"%s"}\n' "$WS" > "$FM_MACHINE_FILE"
  fi
}

# --- Stand-ins ---------------------------------------------------------------

# 0755 whatever the umask, so a shared-group umask of 002 cannot change a case.
BIN="$TMP/bin"
mkdir -p "$BIN"
chmod 0755 "$BIN"
SIM_LOG="$TMP/calls.log"
: > "$SIM_LOG"
UV_TARBALL="$TMP/uv.tar.gz"

# stub NAME BODY — @LOG@ and @TARBALL@ are baked in, because the step runs uv and
# git under `env -i` and a stand-in there sees no inherited variable.
stub() {
  local body="${2//@LOG@/$SIM_LOG}"
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
# curl serves the stand-in uv tarball to whatever -o names.
stub curl 'printf "curl %s\n" "$*" >> @LOG@
while [ $# -gt 0 ]; do [ "$1" = -o ] && { cp @TARBALL@ "$2"; exit 0; }; shift; done
exit 1'
stub docker 'printf "docker %s\n" "$*" >> @LOG@
case "$1" in
  info) exit 0 ;;
  image)
    [ "$2" = inspect ] || exit 0
    for ref in ${FAKE_DOCKER_IMAGES:-}; do [ "$ref" = "$3" ] && exit 0; done
    exit 1 ;;
  run) [ "${FAKE_DOCKER_GPU:-fail}" = ok ] ;;
  *) exit 1 ;;
esac'
stub nvidia-smi '[ -n "${FAKE_NVSMI:-}" ] && printf "%s\n" "$FAKE_NVSMI"
exit 0'

# The uv the step downloads: a stand-in that records its environment and, on
# `sync`, lays down the venv entrypoint where it was told to.
ARCH="$(uname -m)"
mkdir -p "$TMP/uvpkg/uv-$ARCH-unknown-linux-gnu"
cat > "$TMP/uvpkg/uv-$ARCH-unknown-linux-gnu/uv" <<UV
#!/usr/bin/env bash
printf 'uv %s (from %s)\n' "\$*" "\$0" >> $SIM_LOG
env | sort | sed 's/^/uvenv /' >> $SIM_LOG
if [ "\$1" = sync ]; then
  mkdir -p "\$UV_PROJECT_ENVIRONMENT/bin"
  printf '#!/bin/sh\n' > "\$UV_PROJECT_ENVIRONMENT/bin/fm-sim-agent"
  chmod +x "\$UV_PROJECT_ENVIRONMENT/bin/fm-sim-agent"
fi
UV
chmod 0755 "$TMP/uvpkg/uv-$ARCH-unknown-linux-gnu/uv"
tar -czf "$UV_TARBALL" -C "$TMP/uvpkg" "uv-$ARCH-unknown-linux-gnu"
UV_SHA="$(sha256sum "$UV_TARBALL" | cut -d' ' -f1)"

SYS_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export FM_SIM_TEST=1 FM_SIM_TEST_ROOT="$R" FM_SIM_TEST_SOURCE="file://$UPSTREAM" FM_SIM_TEST_UV_SHA256="$UV_SHA"
step()  { env PATH="$BIN:$SYS_PATH" bash "$STEP" "$@" 2>&1; }
isaac() { env PATH="$BIN:$SYS_PATH" bash "$ISAAC_STEP" "$@" 2>&1; }
log() { cat "$SIM_LOG"; }

DIGEST="sha256:$(printf '%064d' 0 | tr 0 a)"
export FAKE_DOCKER_IMAGES="$FM_CUDA_SMOKE_IMAGE $FM_SIM_IMAGE ${FM_SIM_IMAGE%:*}@$DIGEST"
export FAKE_DOCKER_GPU=ok
export FAKE_NVSMI="580.95.05, NVIDIA GeForce RTX 4090, 24564"

# The template fm-sim ships, in the form it ships it.
GOOD_TEMPLATE='# fm-sim-agent — this sim host'"'"'s run control verbs, served over Zenoh.
[Unit]
Description=fm-sim-agent: this sim host'"'"'s run control verbs over Zenoh
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
User=@USER@
WorkingDirectory=@WORKDIR@
EnvironmentFile=/etc/fm-comms.env
ExecStart=@UV@ run --project @WORKDIR@ fm-sim-agent
TimeoutStopSec=60
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target'

gitc() { git -C "$UPSTREAM" -c user.email=test@example.com -c user.name=test "$@"; }

# make_upstream [TEMPLATE] — fm-sim upstream with agent/ committed; sets COMMIT.
make_upstream() {
  rm -rf "$UPSTREAM"
  mkdir -p "$UPSTREAM/agent/systemd" "$UPSTREAM/agent/src/fm_sim_agent"
  printf '%s\n' "${1:-$GOOD_TEMPLATE}" > "$UPSTREAM/agent/systemd/fm-sim-agent.service.in"
  printf '[project]\nname = "fm-sim-agent"\n' > "$UPSTREAM/agent/pyproject.toml"
  printf 'print("agent")\n' > "$UPSTREAM/agent/src/fm_sim_agent/__init__.py"
  git init --quiet "$UPSTREAM"
  git -C "$UPSTREAM" config uploadpack.allowAnySHA1InWant true
  gitc add -A
  gitc commit --quiet -m init
  COMMIT="$(git -C "$UPSTREAM" rev-parse HEAD)"
}

reset_host() { rm -rf "$R"; mkdir -p "$R/etc"; : > "$R/etc/fm-comms.env"; : > "$SIM_LOG"; }
UNIT="$R/etc/systemd/system/$FM_SIM_UNIT"
AGENT="$R$FM_SIM_AGENT_ROOT"

# --- The card names the workload ----------------------------------------------

printf '\n── card ──\n'
assert_eq "sim is a workload the card accepts" "true" \
  "$(_fm_in_list sim "${FM_MACHINE_WORKLOADS[@]}" && echo true || echo false)"
assert_rc "the validator accepts sim" 0 fm_machine_valid_workload sim
assert_eq "the schema's enum carries sim" "true" \
  "$(jq '.properties.workload.enum | index("sim") != null' "$FM_ROOT/$FM_MACHINE_SCHEMA")"
assert_eq "the workstation role registers the step" "sim|91-sim.sh|on" \
  "$(fm_steps_for workstation | grep '^sim|')"
assert_eq "no commit is pinned until fm-sim#43 lands" "" "$FM_SIM_COMMIT_DEFAULT"
assert_eq "uv is pinned for x86_64" "x86_64|1ce5212f8f42dc7427a1bd3db4168d6d1abcf81b38d8c82a5b9d0ddc54ceebfc" \
  "$(printf '%s\n' "${FM_SIM_UV_SHA256_MAP[@]}" | grep '^x86_64|')"

# --- The shared helpers -------------------------------------------------------------

printf '\n── lib helpers ──\n'
card sim
FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_HOME/.local/bin"
assert_rc "fm_uv_bin fails with no uv anywhere" 1 env PATH="$SYS_PATH" bash -c ". '$FM_ROOT/lib.sh'; fm_uv_bin '$FAKE_HOME'"
printf '#!/bin/sh\n' > "$FAKE_HOME/.local/bin/uv"; chmod 0755 "$FAKE_HOME/.local/bin/uv"
assert_eq "fm_uv_bin finds the home's uv off PATH" "$FAKE_HOME/.local/bin/uv" \
  "$(env PATH="$SYS_PATH" bash -c ". '$FM_ROOT/lib.sh'; fm_uv_bin '$FAKE_HOME'")"
assert_eq "fm_workspace_owner is the workspace's owner" "$(id -un)" "$(fm_workspace_owner)"
: > "$SIM_LOG"
assert_eq "fm_as_workspace_owner runs plainly as that owner" "$(id -un)" \
  "$(env PATH="$BIN:$SYS_PATH" bash -c ". '$FM_ROOT/lib.sh'; fm_as_workspace_owner id -un")"
assert_eq "  without sudo" "" "$(log)"
env PATH="$BIN:$SYS_PATH" bash -c ". '$FM_ROOT/lib.sh'; fm_run_as nobody true; fm_run_as root true"
assert_eq "fm_run_as goes through sudo -u for another account, sudo for root" \
  "sudo -u nobody true|sudo true" "$(paste -sd'|' "$SIM_LOG")"
assert_eq "fm_workspace_home reads the owner's home" "$(getent passwd "$(id -un)" | cut -d: -f6)" "$(fm_workspace_home)"

# --- sim-lib, directly ------------------------------------------------------------

printf '\n── sim-lib ──\n'
EXEC="/opt/fm-sim-agent/venv/bin/fm-sim-agent --gpus"
render_good() { sim_render_unit "$1" fm-sim /opt/fm-sim-agent/project "$EXEC" /etc/fm-comms.env "test"; }
out="$(render_good "$GOOD_TEMPLATE")"
assert_has "the user is filled" "$out" "User=fm-sim"
assert_has "the workdir is filled" "$out" "WorkingDirectory=/opt/fm-sim-agent/project"
assert_has "ExecStart is replaced" "$out" "ExecStart=$EXEC"
assert_lacks "no placeholder survives" "$out" "=@"
assert_lacks "the service never runs uv" "$out" "run --project"
refused() {  # label template needle
  local rc=0 out
  out="$(render_good "$2" 2>&1)" || rc=$?
  assert_eq "refused: $1" 1 "$rc"
  assert_has "  and says why" "$out" "$3"
}
refused "an ExecStartPre" "${GOOD_TEMPLATE/Restart=always/Restart=always
ExecStartPre=/bin/sh -c id}" "a key the allowlist does not hold"
refused "User=root" "${GOOD_TEMPLATE/User=@USER@/User=root}" "User must be @USER@"
refused "a second ExecStart" "${GOOD_TEMPLATE/Restart=always/Restart=always
ExecStart=/bin/sh}" "a repeated key"
refused "a changed ExecStart" "${GOOD_TEMPLATE/@WORKDIR@ fm-sim-agent/@WORKDIR@ fm-sim-agent --gpus}" "ExecStart must be"
refused "an extra section" "$GOOD_TEMPLATE
[Socket]
ListenStream=1" "an unknown section"
refused "a continued line" "${GOOD_TEMPLATE/Type=simple/Type=simple \\}" "a continued line"
refused "another EnvironmentFile" "${GOOD_TEMPLATE/\/etc\/fm-comms.env/\/tmp\/x.env}" "EnvironmentFile must be"
refused "no ExecStart" "${GOOD_TEMPLATE/ExecStart=@UV@ run --project @WORKDIR@ fm-sim-agent/}" "it has no [Service]ExecStart"
rc=0; sim_render_unit "$GOOD_TEMPLATE" fm-sim /opt/x '/opt/x --image a%b' /etc/fm-comms.env t >/dev/null 2>&1 || rc=$?
assert_eq "an operator word carrying % is refused" 1 "$rc"
assert_rc "sim_safe_word refuses a space" 1 sim_safe_word "a b"
assert_rc "sim_safe_word refuses \$" 1 sim_safe_word 'a$b'
assert_rc "sim_safe_word accepts a path" 0 sim_safe_word /data/sim-runs

tree_line() { printf '%s blob %s\t%s\n' "$1" "$(printf '%040d' 0)" "$2"; }
assert_rc "sim_tree_ok accepts plain files" 0 bash -c \
  ". '$FM_ROOT/lib.sh'; . '$FM_ROOT/scripts/internal/sim-lib.sh'; printf '%s\n%s\n' \"$(tree_line 100644 agent/a)\" \"$(tree_line 100755 agent/b)\" | sim_tree_ok"
assert_rc "sim_tree_ok refuses a symlink" 1 bash -c \
  ". '$FM_ROOT/lib.sh'; . '$FM_ROOT/scripts/internal/sim-lib.sh'; printf '%s\n' \"$(tree_line 120000 agent/l)\" | sim_tree_ok"
assert_rc "sim_tree_ok refuses a submodule" 1 bash -c \
  ". '$FM_ROOT/lib.sh'; . '$FM_ROOT/scripts/internal/sim-lib.sh'; printf '%s\n' \"$(tree_line 160000 agent/m)\" | sim_tree_ok"
assert_rc "sim_tree_ok refuses an empty tree" 1 bash -c \
  ". '$FM_ROOT/lib.sh'; . '$FM_ROOT/scripts/internal/sim-lib.sh'; printf '' | sim_tree_ok"

assert_rc "the test root needs FM_SIM_TEST=1" 1 env FM_SIM_TEST=0 bash -c \
  ". '$FM_ROOT/lib.sh'; . '$FM_ROOT/scripts/internal/sim-lib.sh'; sim_test_root_ok '$R'"
assert_rc "the test root must sit under the temp dir" 1 bash -c \
  ". '$FM_ROOT/lib.sh'; . '$FM_ROOT/scripts/internal/sim-lib.sh'; sim_test_root_ok /etc"
assert_rc "the test root refuses a temp dir of /" 1 env TMPDIR=/ bash -c \
  ". '$FM_ROOT/lib.sh'; . '$FM_ROOT/scripts/internal/sim-lib.sh'; sim_test_root_ok /etc"
assert_rc "the test root refuses the temp dir itself" 1 env TMPDIR=/tmp bash -c \
  ". '$FM_ROOT/lib.sh'; . '$FM_ROOT/scripts/internal/sim-lib.sh'; sim_test_root_ok /tmp/"
assert_rc "the test root refuses a sibling that only shares the prefix" 1 env TMPDIR=/tmp bash -c \
  ". '$FM_ROOT/lib.sh'; . '$FM_ROOT/scripts/internal/sim-lib.sh'; sim_test_root_ok /tmpfoo/x"
assert_rc "the test root accepts a path under the temp dir" 0 env TMPDIR=/tmp bash -c \
  ". '$FM_ROOT/lib.sh'; . '$FM_ROOT/scripts/internal/sim-lib.sh'; sim_test_root_ok /tmp/x"
assert_rc "the test root refuses .." 1 bash -c \
  ". '$FM_ROOT/lib.sh'; . '$FM_ROOT/scripts/internal/sim-lib.sh'; sim_test_root_ok '$TMP/../../etc'"

# --- The test hooks stay out of production --------------------------------------

printf '\n── test hooks ──\n'
rc=0; out="$(env -u FM_SIM_TEST PATH="$BIN:$SYS_PATH" bash "$STEP" check 2>&1)" || rc=$?
assert_eq "a test root without FM_SIM_TEST=1 is refused" 1 "$rc"
assert_has "  by name" "$out" "FM_SIM_TEST_ROOT is a test hook and needs FM_SIM_TEST=1"
rc=0; out="$(FM_SIM_TEST_ROOT=/etc step check)" || rc=$?
assert_eq "a test root outside the temp dir is refused" 1 "$rc"
rc=0; out="$(env -u FM_SIM_TEST_ROOT -u FM_SIM_TEST_UV_SHA256 PATH="$BIN:$SYS_PATH" bash "$STEP" check 2>&1)" || rc=$?
assert_eq "a test source without a test root is refused" 1 "$rc"
assert_has "  by name" "$out" "need FM_SIM_TEST_ROOT"
rc=0; out="$(env -u FM_SIM_TEST_ROOT -u FM_SIM_TEST_SOURCE PATH="$BIN:$SYS_PATH" bash "$STEP" check 2>&1)" || rc=$?
assert_eq "a test uv checksum without a test root is refused" 1 "$rc"

# --- The dry run ----------------------------------------------------------------

printf '\n── dry run ──\n'
make_upstream
reset_host
before="$(find "$TMP" -path "$SIM_LOG" -prune -o -print | LC_ALL=C sort)"
rc=0
out="$(FM_SIM_COMMIT="$COMMIT" step install --dry-run)" || rc=$?
after="$(find "$TMP" -path "$SIM_LOG" -prune -o -print | LC_ALL=C sort)"
assert_eq "dry run exits 0" 0 "$rc"
assert_eq "dry run creates nothing" "$before" "$after"
assert_eq "dry run runs no privileged tool" "" "$(grep -v '^docker' "$SIM_LOG" || true)"
assert_has "dry run plans root's own fetch" "$out" "would fetch  $COMMIT from file://$UPSTREAM into $FM_SIM_AGENT_ROOT/src.git (as root)"
assert_has "dry run names the uv checksum" "$out" "checked against sha256 $UV_SHA"
assert_has "no digest: the plan grants and enables nothing" "$out" "would write the unit, grant nothing, enable nothing"
assert_has "no pinned commit: the plan installs no agent" "$(step install --dry-run)" "would install no agent"
assert_rc "a commit that is not a full SHA is refused" 1 env FM_SIM_COMMIT=main PATH="$BIN:$SYS_PATH" bash "$STEP" install --dry-run
assert_rc "a malformed digest is refused" 1 env FM_SIM_COMMIT="$COMMIT" FM_SIM_IMAGE_DIGEST='sha256:nope; rm -rf /' \
  PATH="$BIN:$SYS_PATH" bash "$STEP" install --dry-run

# --- The install path ----------------------------------------------------------------

printf '\n── install ──\n'
inst() { env FM_SIM_COMMIT="$COMMIT" FM_SIM_IMAGE_DIGEST="$DIGEST" PATH="$BIN:$SYS_PATH" bash "$STEP" install 2>&1; }

# Unattended, with a digest, and a yes on stdin: the NONINTERACTIVE gate alone
# declines the grant.
make_upstream
reset_host
rc=0
out="$(printf 'y\n' | NONINTERACTIVE=1 UV_INDEX_URL=http://evil.example UV_EXTRA_INDEX_URL=http://evil.example inst)" || rc=$?
assert_eq "install exits 0 unattended" 0 "$rc"
assert_eq "the unit is written" "true" "$(exists "$UNIT")"
assert_has "the unit runs the entrypoint with the pinned image" "$(cat "$UNIT")" \
  "ExecStart=$FM_SIM_AGENT_ROOT/venv/bin/fm-sim-agent --image ${FM_SIM_IMAGE%:*}@$DIGEST --runs-dir $FM_SIM_RUNS_DIR ${FM_SIM_AGENT_FLAGS[*]}"
assert_has "the unit names its commit" "$(cat "$UNIT")" "from fm-sim $COMMIT:agent/systemd"
assert_eq "root fetched the commit into its own repository" "$COMMIT" \
  "$(git --git-dir="$AGENT/src.git" rev-parse --verify "$COMMIT^{commit}")"
assert_has "  with replace objects off and no inherited config" "$(log)" \
  "sudo env -i PATH=/usr/bin:/bin HOME=/nonexistent GIT_NO_REPLACE_OBJECTS=1 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 git"
assert_eq "the agent is copied from the commit" 'print("agent")' "$(cat "$AGENT/project/src/fm_sim_agent/__init__.py")"
assert_eq "the copy records its commit" "$COMMIT" "$(cat "$AGENT/.fm-commit")"
assert_eq "agent files are 644" "644" "$(stat -c '%a' "$AGENT/project/pyproject.toml")"
assert_eq "agent directories are 755" "755" "$(stat -c '%a' "$AGENT/project/src")"
assert_has "ownership is handed to root" "$(log)" "chown -R root:root"
assert_eq "uv is the pinned tarball's" "$UV_SHA" "$(cat "$AGENT/bin/.uv-sha256")"
assert_has "the venv is built non-editable and frozen" "$(log)" \
  "sync --quiet --frozen --no-dev --no-editable --directory $AGENT/project (from $AGENT/bin/uv)"
assert_has "  with no uv config" "$(log)" "uvenv UV_NO_CONFIG=1"
assert_eq "  and no inherited index" 0 "$(count 'uvenv UV_.*INDEX')"
assert_eq "  and no inherited PATH" "uvenv PATH=/usr/bin:/bin" "$(grep '^uvenv PATH=' "$SIM_LOG")"
assert_eq "the runs dir is 2770" "2770" "$(stat -c '%a' "$R$FM_SIM_RUNS_DIR")"
assert_has "the account is created" "$(log)" "useradd --system --user-group --create-home --home-dir $FM_SIM_HOME"
assert_has "the declined grant is said" "$out" "docker grant declined"
assert_eq "usermod never ran" 0 "$(count '^usermod')"
assert_eq "systemctl enable never ran" 0 "$(count '^systemctl enable')"

# Interactive, with a digest: the grant is given, the unit enabled and started.
: > "$SIM_LOG"
out="$(printf 'y\n' | inst)"
assert_has "a yes adds the account to docker" "$(log)" "usermod -aG docker $FM_SIM_USER"
assert_has "the unit is enabled" "$(log)" "systemctl enable $FM_SIM_UNIT"
assert_has "an unchanged unit is started, not restarted" "$(log)" "systemctl start $FM_SIM_UNIT"
assert_eq "an unchanged unit reloads nothing" 0 "$(count 'daemon-reload')"
assert_eq "the pinned tree is not copied again" 0 "$(count 'chown -R root:root')"
assert_eq "uv is not fetched again" 0 "$(count '^curl')"
assert_eq "the commit is not fetched again" 0 "$(count ' fetch ')"

# No digest: the unit is written, and nothing is granted or enabled, even on a yes.
reset_host
out="$(printf 'y\n' | env FM_SIM_COMMIT="$COMMIT" PATH="$BIN:$SYS_PATH" bash "$STEP" install 2>&1)"
assert_eq "no digest: the unit is still written" "true" "$(exists "$UNIT")"
assert_has "no digest: the step says it will not enable" "$out" "written, not enabled, no docker grant"
assert_eq "no digest: usermod never ran" 0 "$(count '^usermod')"
assert_eq "no digest: systemctl enable never ran" 0 "$(count '^systemctl enable')"

# No commit pinned: no agent, no unit.
reset_host
rc=0; out="$(NONINTERACTIVE=1 FM_SIM_IMAGE_DIGEST="$DIGEST" step install)" || rc=$?
assert_eq "no commit: exits 0 at the gate" 0 "$rc"
assert_has "no commit: says so" "$out" "no fm-sim commit pinned (FM_SIM_COMMIT_DEFAULT) — no agent installed"
assert_eq "no commit: no agent tree" "false" "$(exists "$AGENT")"

# --- The workspace's .git is never read ----------------------------------------

printf '\n── workspace .git ──\n'
make_upstream
reset_host
# A workspace checkout whose .git says the pinned commit is something else.
git clone --quiet "$UPSTREAM" "$WS/fm-sim"
printf 'print("evil")\n' > "$WS/fm-sim/agent/src/fm_sim_agent/__init__.py"
git -C "$WS/fm-sim" -c user.email=e@example.com -c user.name=e commit --quiet -am evil
evil="$(git -C "$WS/fm-sim" rev-parse HEAD)"
git -C "$WS/fm-sim" reset --quiet --hard "$COMMIT"
git -C "$WS/fm-sim" replace "$COMMIT" "$evil"
rc=0; NONINTERACTIVE=1 inst >/dev/null || rc=$?
assert_eq "install with a tampered workspace .git exits 0" 0 "$rc"
assert_eq "a replace ref in the workspace has no effect" 'print("agent")' \
  "$(cat "$AGENT/project/src/fm_sim_agent/__init__.py")"
rm -rf "$WS/fm-sim"
reset_host
rc=0; NONINTERACTIVE=1 inst >/dev/null || rc=$?
assert_eq "install needs no workspace checkout at all" "0|$COMMIT" "$rc|$(cat "$AGENT/.fm-commit" 2>/dev/null)"

# --- Refusals ---------------------------------------------------------------------

printf '\n── refusals ──\n'

# A pin upstream does not hold.
make_upstream
reset_host
rc=0; out="$(NONINTERACTIVE=1 env FM_SIM_COMMIT="$(printf '%040d' 7)" FM_SIM_IMAGE_DIGEST="$DIGEST" \
  PATH="$BIN:$SYS_PATH" bash "$STEP" install 2>&1)" || rc=$?
assert_eq "a pin upstream does not hold fails install" 1 "$rc"
assert_has "  as a failed fetch" "$out" "fetching $(printf '%040d' 7) from file://$UPSTREAM failed"
assert_eq "  and nothing is copied" "false" "$(exists "$AGENT/project")"

# A symlink in agent/, refused before anything is extracted.
make_upstream
ln -s /etc/passwd "$UPSTREAM/agent/link"
gitc add -A; gitc commit --quiet -m link
COMMIT="$(git -C "$UPSTREAM" rev-parse HEAD)"
reset_host
rc=0; out="$(NONINTERACTIVE=1 inst)" || rc=$?
assert_eq "a symlink in agent/ fails install" 1 "$rc"
assert_has "  and is named" "$out" "refusing a tree entry of mode 120000: agent/link"
assert_eq "  nothing is extracted" "" "$(find "$AGENT" -maxdepth 1 -name '.project.*' -o -maxdepth 1 -name project)"
assert_eq "  no tar ran" 0 "$(count 'tar -x')"

# A uv tarball that does not match its pin.
make_upstream
reset_host
rc=0; out="$(NONINTERACTIVE=1 FM_SIM_TEST_UV_SHA256="$(printf '%064d' 0)" inst)" || rc=$?
assert_eq "a uv checksum mismatch fails install" 1 "$rc"
assert_has "  and is named" "$out" "uv $FM_UV_VERSION checksum mismatch"
assert_eq "  no uv is installed" "false" "$(exists "$AGENT/bin/uv")"
assert_eq "  no uv ran" 0 "$(count '^uv ')"
assert_eq "  no unit is written" "false" "$(exists "$UNIT")"

# A template that fails the allowlist stops install before anything is laid down.
make_upstream "${GOOD_TEMPLATE/User=@USER@/User=root}"
reset_host
rc=0; out="$(NONINTERACTIVE=1 inst)" || rc=$?
assert_eq "a refused template fails install" 1 "$rc"
assert_eq "  before the account is made" 0 "$(count '^useradd')"
assert_eq "  and before anything is copied" "false" "$(exists "$AGENT/project")"

# Every privileged call site, failed on its own: install exits 1, names what
# failed, and nothing claims to be enabled. Entries are "argv text|what".
SITES=(
  "install -d -o root -g root -m 0755 $AGENT|creating $FM_SIM_AGENT_ROOT failed"
  "init --quiet --bare|creating $FM_SIM_AGENT_ROOT/src.git failed"
  " fetch --quiet --depth 1|from file://$UPSTREAM failed"
  "useradd|creating account $FM_SIM_USER failed"
  "mktemp -d $AGENT/.project|creating a staging directory failed"
  "tar -x --no-same-owner --no-same-permissions|extracting agent/ at"
  "chown -R root:root|handing $FM_SIM_AGENT_ROOT/project to root failed"
  "-type d -exec chmod|setting directory modes failed"
  "-type f -exec chmod|setting file modes failed"
  "rm -rf $AGENT/project|removing the old $FM_SIM_AGENT_ROOT/project failed"
  "mv $AGENT/.project|moving the new $FM_SIM_AGENT_ROOT/project into place failed"
  "tee $AGENT/.fm-commit|recording the installed commit failed"
  "-m 0755 $AGENT/bin|creating $FM_SIM_AGENT_ROOT/bin failed"
  "mktemp -d $AGENT/.uv|creating a staging directory failed"
  "curl -fsSL|downloading uv $FM_UV_VERSION failed"
  "tar -xzf|unpacking uv failed"
  "unknown-linux-gnu/uv $AGENT/bin/uv|installing $FM_SIM_AGENT_ROOT/bin/uv failed"
  "tee $AGENT/bin/.uv-sha256|recording the uv checksum failed"
  "-m 0700 $R$FM_SIM_UV_CACHE|creating $FM_SIM_UV_CACHE failed"
  "sync --quiet --frozen|building $FM_SIM_AGENT_ROOT/venv failed"
  "chmod -R u+rwX|setting venv modes failed"
  "-m 2770|creating $FM_SIM_RUNS_DIR failed"
  "mktemp -d $AGENT/.unit|creating a staging directory failed"
  "tee $AGENT/.unit|staging /etc/systemd/system/$FM_SIM_UNIT failed"
  "install -d -m 0755 $R/etc/systemd|creating /etc/systemd/system failed"
  "-m 0644 $AGENT/.unit|writing /etc/systemd/system/$FM_SIM_UNIT failed"
  "systemctl daemon-reload|reloading systemd failed"
  "usermod -aG docker|adding $FM_SIM_USER to the docker group failed"
  "systemctl enable|enabling $FM_SIM_UNIT failed"
  "systemctl restart|restarting $FM_SIM_UNIT failed"
)
for site in "${SITES[@]}"; do
  pattern="${site%%|*}"
  what="${site#*|}"
  make_upstream
  reset_host
  rc=0; out="$(printf 'y\n' | FAKE_FAIL="$pattern" inst)" || rc=$?
  assert_eq "failing '$pattern' fails install" 1 "$rc"
  assert_has "  and names it" "$out" "$what"
  assert_lacks "  and nothing claims enabled" "$out" "enabled and running"
done
# The marker is written last: a failure before it leaves none.
for pattern in "chown -R root:root" "mv $AGENT/.project"; do
  make_upstream
  reset_host
  printf 'y\n' | FAKE_FAIL="$pattern" inst >/dev/null || true
  assert_eq "failing '$pattern' leaves no installed-commit marker" "false" "$(exists "$AGENT/.fm-commit")"
done
# start is reached only when the unit was already current.
make_upstream
reset_host
printf 'y\n' | inst >/dev/null
rc=0; out="$(printf 'y\n' | FAKE_FAIL="systemctl start" inst)" || rc=$?
assert_eq "failing 'systemctl start' fails install" 1 "$rc"
assert_has "  and names it" "$out" "starting $FM_SIM_UNIT failed"

# --- check and uninstall ------------------------------------------------------------

printf '\n── check and uninstall ──\n'
make_upstream
reset_host
NONINTERACTIVE=1 inst >/dev/null
out="$(FM_SIM_COMMIT="$COMMIT" FM_SIM_IMAGE_DIGEST="$DIGEST" step check)"
assert_has "check sees a current unit" "$out" "$FM_SIM_UNIT installed and current"
assert_has "check sees the pinned agent" "$out" "is the agent at the pinned commit"
assert_has "check sees the pinned uv" "$out" "is the pinned uv $FM_UV_VERSION"
assert_rc "check exits 0" 0 step check
: > "$SIM_LOG"
rc=0; out="$(FAKE_FAIL="systemctl disable" step uninstall)" || rc=$?
assert_eq "a failing disable fails uninstall" 1 "$rc"
assert_has "  and names it" "$out" "disabling $FM_SIM_UNIT failed"
assert_eq "  and the unit stays" "true" "$(exists "$UNIT")"
: > "$SIM_LOG"
assert_rc "uninstall exits 0" 0 step uninstall
assert_eq "uninstall removes the unit" "false" "$(exists "$UNIT")"
assert_eq "uninstall removes the agent tree" "false" "$(exists "$AGENT")"
assert_eq "uninstall leaves the runs" "true" "$(exists "$R$FM_SIM_RUNS_DIR")"
assert_has "uninstall disables the unit" "$(log)" "systemctl disable --now $FM_SIM_UNIT"

# --- The bridge report ---------------------------------------------------------------

printf '\n── bridge ──\n'
card workstation
out="$(step check)"
assert_has "another workload names the profile it selects" "$out" "card workload is 'workstation' — fm-comms renders bridge-workstation.json5, not bridge-sim.json5"
assert_eq "check leaves the card as it was" "workstation" "$(jq -r .workload "$FM_MACHINE_FILE")"
card ""
assert_has "no workload is named" "$(step check)" "the card names no workload"
card sim
assert_has "sim selects bridge-sim" "$(step check)" "card workload sim — fm-comms renders bridge-sim.json5"

# --- The Isaac preflight (90-isaac-sim's check) ---------------------------------------

printf '\n── isaac preflight ──\n'
: > "$SIM_LOG"
out="$(isaac check)"
assert_has "a ready host says so" "$out" "this host can run Isaac Sim 4.5"
assert_has "the GPU is named" "$out" "GPU present: NVIDIA GeForce RTX 4090 (24564 MiB)"
assert_has "the driver is compared with the minimum" "$out" "driver 580.95.05 (Isaac Sim 4.5 wants $FM_ISAAC_DRIVER_MIN or later)"
assert_has "the container test never pulls, and runs as nobody" "$(log)" \
  "docker run --rm --pull=never --user 65534:65534 --gpus all $FM_CUDA_SMOKE_IMAGE nvidia-smi"
assert_has "an old driver is named" "$(FAKE_NVSMI="470.239.06, Quadro P2000, 5120" isaac check)" \
  "driver 470.239.06 is older than $FM_ISAAC_DRIVER_MIN"
assert_has "no GPU is named" "$(FAKE_NVSMI="" isaac check)" "nvidia-smi finds no GPU"
mv "$BIN/nvidia-smi" "$TMP/nvidia-smi.off"
assert_has "no driver is named" "$(isaac check)" "no nvidia-smi — no NVIDIA driver here"
mv "$TMP/nvidia-smi.off" "$BIN/nvidia-smi"
assert_has "a toolkit that does not pass the GPU through is named" "$(FAKE_DOCKER_GPU=fail isaac check)" \
  "the GPU is not visible inside containers"
: > "$SIM_LOG"
assert_has "a missing smoke image is named, not pulled" "$(FAKE_DOCKER_IMAGES="" isaac check)" "$FM_CUDA_SMOKE_IMAGE not pulled"
assert_eq "  and no container runs" 0 "$(count '^docker run')"

# --- install.sh's own dry run walks the step ---------------------------------------

printf '\n── install.sh --dry-run ──\n'
out="$(env PATH="$BIN:$SYS_PATH" FM_SELFTEST=0 FM_NO_MODIFY_PATH=1 FM_ALLOW_OS_MISMATCH=1 \
  bash "$FM_ROOT/install.sh" --workstation --dry-run --only sim 2>&1 || true)"
assert_has "the role's dry run plans the sim step" "$out" "would run: sim (91-sim.sh) [install]"

# --- Result ----------------------------------------------------------------

echo
if [ "$FAIL" -eq 0 ]; then
  fm_ok "$PASS passed"
else
  fm_err "$FAIL failed, $PASS passed"
  exit 1
fi
