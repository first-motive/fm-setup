#!/usr/bin/env bash
#
# test-sim-cloud.sh — exercise the sim-cloud role: its step order, its refusal
# of an incomplete host.env, the card and env file it writes, the tailnet join,
# and the readiness gate it ends on.
#
#   ./scripts/dev/test-sim-cloud.sh
#
# The role runs as root from a cloud-init bootstrap whose output reaches the
# instance's console log, so the join's cases are about the auth key: it never
# appears in the run's output or in any command's argv, and the file it passes
# through is gone afterwards, whether the join worked or not.
#
# aws, tailscale, sudo, systemctl, nvidia-smi, id and hostnamectl are stand-ins
# on PATH that record their argv. The steps' test hooks (FM_SIM_TEST=1 with
# FM_SIM_TEST_ROOT) point every path they write at a temp root, and
# FM_MACHINE_FILE points the card there too. No root, daemon, or network.
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
# shellcheck source=../internal/sim-cloud-lib.sh disable=SC1091
. "$FM_ROOT/scripts/internal/sim-cloud-lib.sh"

[ "$(uname -s)" = "Linux" ] || { fm_warn "sim-cloud is a Linux role — skipping on $(uname -s)"; exit 0; }
fm_require_cmd jq
fm_require_cmd git

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP
unset FM_HOME NONINTERACTIVE FM_ROLE
R="$TMP/root"
mkdir -p "$R/run" "$R/etc"
export FM_MACHINE_FILE="$TMP/machine.json"

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
assert_rc() {
  local label="$1" want="$2" got=0; shift 2
  "$@" >/dev/null 2>&1 || got=$?
  assert_eq "$label" "$want" "$got"
}

# --- host.env, as the stack's bootstrap writes it --------------------------------

HEAD_SHA="$(git -C "$FM_ROOT" rev-parse HEAD)"
SIM_COMMIT="$(printf '%040d' 0 | tr 0 b)"
DIGEST="sha256:$(printf '%064d' 0 | tr 0 c)"
# A key-shaped sentinel: the cases below grep every output and argv for it.
KEY="tskey-auth-kSENTINEL0123-NeverPrintThisValue0123456789"
HOST_ENV=(
  FM_MACHINE_NAME=sim-cloud
  "FM_SETUP_SHA=$HEAD_SHA"
  "FM_SIM_COMMIT=$SIM_COMMIT"
  "FM_SIM_IMAGE_DIGEST=$DIGEST"
  FM_ROUTER_ENDPOINT=tcp/fm-router:7447
  FM_TS_AUTHKEY_SSM_PARAMETER=/fm-sim/cloud-host/tailscale-auth-key
  FM_TS_TAG=tag:sim-cloud
  FM_SIM_CLOUD_REGION=eu-west-1
  FM_SIM_IDLE_MINUTES=15
  FM_SIM_MAX_LIFETIME_MINUTES=480
)
export "${HOST_ENV[@]}"

# --- Stand-ins ---------------------------------------------------------------

BIN="$TMP/bin"
mkdir -p "$BIN"
chmod 0755 "$BIN"
LOG="$TMP/calls.log"
: > "$LOG"
TS_STATE="$TMP/ts-state"   # BackendState|tags, read by the tailscale stand-in
stub() {
  local body="${2//@LOG@/$LOG}"
  body="${body//@TS@/$TS_STATE}"
  body="${body//@KEY@/$KEY}"
  printf '#!/usr/bin/env bash\n%s\n' "$body" > "$BIN/$1"
  chmod 0755 "$BIN/$1"
}
stub sudo 'printf "sudo %s\n" "$*" >> @LOG@
[ -n "${FAKE_FAIL:-}" ] && case "$*" in *"$FAKE_FAIL"*) exit 1 ;; esac
exec "$@"'
stub install 'args=()
while [ $# -gt 0 ]; do case "$1" in -o|-g) shift 2 ;; *) args+=("$1"); shift ;; esac; done
exec /usr/bin/install "${args[@]}"'
stub hostnamectl 'printf "hostnamectl %s\n" "$*" >> @LOG@'
# aws prints the key on stdout, as `--output text` does, or fails as aws does.
stub aws 'printf "aws %s\n" "$*" >> @LOG@
case "${FAKE_AWS:-ok}" in
  ok)        printf "%s\n" "@KEY@" ;;
  malformed) printf "not-a-key %s\n" "@KEY@" ;;
  *)         echo "An error occurred (ParameterNotFound) when calling the GetParameter operation" >&2; exit 254 ;;
esac'
# tailscale: `status --json` from the state file; `up` checks the key file it
# is pointed at holds the key, records where it was, and joins.
stub tailscale 'printf "tailscale %s\n" "$*" >> @LOG@
state="$(cat @TS@ 2>/dev/null || echo "NeedsLogin|")"
case "$1" in
  status)
    tags="${state#*|}"
    jq -n --arg s "${state%%|*}" --arg t "$tags" "{BackendState: \$s, Self: {Tags: (\$t | split(\",\") | map(select(. != \"\")))}}" ;;
  up)
    for a in "$@"; do
      case "$a" in
        --auth-key=file:*) f="${a#--auth-key=file:}"; printf "%s\n" "$f" > @TS@.keyfile
          [ "$(cat "$f")" = "@KEY@" ] || { echo "bad key file" >&2; exit 1; }
          stat -c "%a" "$f" > @TS@.keymode; stat -c "%a" "$(dirname "$f")" > @TS@.dirmode ;;
        --advertise-tags=*) t="${a#--advertise-tags=}" ;;
      esac
    done
    [ "${FAKE_TS_UP:-ok}" = ok ] || exit 1
    printf "Running|%s\n" "${FAKE_TS_GRANTED:-$t}" > @TS@ ;;
  logout) echo "NeedsLogin|" > @TS@ ;;
esac'
stub systemctl 'printf "systemctl %s\n" "$*" >> @LOG@
[ -n "${FAKE_DOWN:-}" ] && case "$*" in *"$FAKE_DOWN"*) exit 3 ;; esac
exit 0'
stub nvidia-smi '[ "${FAKE_NVSMI:-ok}" = ok ]'
stub id 'if [ "$1" = -nG ] && [ "${2:-}" = fm-sim ]; then echo "${FAKE_GROUPS:-fm-sim docker}"; else exec /usr/bin/id "$@"; fi'

SYS_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export FM_SIM_TEST=1 FM_SIM_TEST_ROOT="$R" FM_SIM_TEST_SETTLE=0
step() { local file="$1"; shift; env PATH="$BIN:$SYS_PATH" FM_ROLE=sim-cloud bash "$FM_ROOT/scripts/steps/$file" "$@" 2>&1; }
front() { env PATH="$BIN:$SYS_PATH" FM_NO_MODIFY_PATH=1 FM_ALLOW_OS_MISMATCH=1 bash "$FM_ROOT/install.sh" "$@" 2>&1; }

# --- The role -----------------------------------------------------------------

printf '\n── role ──\n'
ids="$(fm_steps_for sim-cloud | cut -d'|' -f1 | paste -sd' ')"
assert_eq "the role's steps, in order" \
  "sim-cloud-host base-deps sim-cloud-card workspace data-root fm-cli docker nvidia-container tailscale tailscale-authkey comms-bridge users agent-ruleset sim sim-cloud-ready" "$ids"
for gone in system-update nvidia etckeeper fm-policy ffmpeg; do
  assert_lacks "no $gone step" " $ids " " $gone "
done
assert_eq "fm-comms is pinned to the tag fm_ros2 uses" "v0.2.7" "$FM_COMMS_TAG"
assert_rc "  by a full commit" 0 bash -c "printf '%s' '$FM_COMMS_COMMIT' | grep -Eqx '[0-9a-f]{40}'"
assert_eq "the bridge carries a Jazzy graph" jazzy "$FM_SIM_CLOUD_ROS_DISTRO"
assert_eq "every step is on" "" "$(fm_steps_for sim-cloud | grep -v '|on$' || true)"
assert_eq "the role accepts 24.04 and 26.04" "noble resolute" "$(fm_role_codename sim-cloud)"
for codename in noble resolute jammy; do
  rc=0; FAKE_CODENAME="$codename" bash -c ". '$FM_ROOT/lib.sh'; . '$FM_ROOT/scripts/manifest.sh'
    fm_os_codename() { echo \"\$FAKE_CODENAME\"; }; fm_require_role_os sim-cloud 1" >/dev/null 2>&1 || rc=$?
  want=0; [ "$codename" = jammy ] && want=1
  assert_eq "an install on $codename exits $want" "$want" "$rc"
done
assert_eq "sim-cloud is a card role" "true" "$(_fm_in_list sim-cloud "${FM_MACHINE_ROLES[@]}" && echo true || echo false)"
assert_eq "the schema's role enum carries sim-cloud" "true" \
  "$(jq '.properties.role.enum | index("sim-cloud") != null' "$FM_ROOT/$FM_MACHINE_SCHEMA")"
assert_rc "the name sim-cloud is valid for the role" 0 fm_machine_valid_name sim-cloud sim-cloud
assert_rc "  and for no other role" 1 fm_machine_valid_name sim-cloud workstation
assert_rc "fm-sim-01 is valid for the role" 0 fm_machine_valid_name fm-sim-01 sim-cloud
assert_eq "the schema accepts sim-cloud as a name" "true" \
  "$(jq -r '.properties.name.pattern' "$FM_ROOT/$FM_MACHINE_SCHEMA" | { read -r re; [[ sim-cloud =~ $re ]] && echo true || echo false; })"
# HuJSON is JSON with comments and trailing commas; strip both and jq reads it.
acl() { sed 's|//.*||' "$FM_ROOT/$FM_SIM_CLOUD_ACL_TEMPLATE" | tr -d '\n' | sed -E 's/,[[:space:]]*([]}])/\1/g' | jq -c "$1"; }
assert_eq "the ACL template grants tcp/7447 only" '["tcp:7447"]' "$(acl '.grants[0].ip')"
assert_eq "  from tag:sim-cloud only" '["tag:sim-cloud"]' "$(acl '.grants[0].src')"
assert_eq "  in one grant" 1 "$(acl '.grants | length')"

# --- install.sh refuses an incomplete host.env -------------------------------------

printf '\n── install.sh --sim-cloud ──\n'
rc=0; out="$(front --sim-cloud --dry-run)" || rc=$?
assert_eq "a complete host.env: the dry run exits 0" 0 "$rc"
plan="$(printf '%s\n' "$out" | sed -n 's/.*would run: \([a-z0-9-]*\) .*/\1/p' | paste -sd' ')"
assert_eq "  and walks the role's steps in order" "$ids" "$plan"
assert_has "the help names the flag" "$(front --help)" "--sim-cloud"

for var in "${FM_SIM_CLOUD_REQUIRED_ENV[@]}"; do
  rc=0; out="$(env -u "$var" PATH="$BIN:$SYS_PATH" FM_NO_MODIFY_PATH=1 FM_ALLOW_OS_MISMATCH=1 \
    bash "$FM_ROOT/install.sh" --sim-cloud --dry-run 2>&1)" || rc=$?
  assert_eq "no $var: refused" 1 "$rc"
  assert_has "  by name" "$out" "$var is not set"
  assert_lacks "  before any step" "$out" "would run:"
done
malformed() {  # var value needle
  local rc=0 out
  out="$(env "$1=$2" PATH="$BIN:$SYS_PATH" FM_NO_MODIFY_PATH=1 FM_ALLOW_OS_MISMATCH=1 \
    bash "$FM_ROOT/install.sh" --sim-cloud --dry-run 2>&1)" || rc=$?
  assert_eq "malformed $1 ('$2'): refused" 1 "$rc"
  assert_has "  and says why" "$out" "$3"
  assert_lacks "  before any step" "$out" "would run:"
}
malformed FM_SIM_COMMIT main "FM_SIM_COMMIT is malformed"
malformed FM_SIM_IMAGE_DIGEST 'sha256:nope; rm -rf /' "FM_SIM_IMAGE_DIGEST is malformed"
malformed FM_ROUTER_ENDPOINT tcp/fm-router:8080 "FM_ROUTER_ENDPOINT is malformed"
malformed FM_TS_TAG sim-cloud "FM_TS_TAG is malformed"
malformed FM_MACHINE_NAME fm-ws-01 "does not match role 'sim-cloud'"
malformed FM_ROUTER_ENDPOINT $'tcp/fm-router:7447\nFM_EVIL=1' "holds a newline"
malformed FM_SETUP_SHA "$(printf '%040d' 9)" "not FM_SETUP_SHA"
rc=0; out="$(front --sim-cloud --check --only sim-cloud-host)" || rc=$?
assert_eq "a check still runs" 0 "$rc"

# --- sim-cloud-host -------------------------------------------------------------

printf '\n── sim-cloud-host ──\n'
APT_CONF="$R/etc/apt/apt.conf.d/90fm-lock-timeout"
rc=0; out="$(step 01-sim-cloud-host.sh install)" || rc=$?
assert_eq "install exits 0" 0 "$rc"
assert_has "apt waits for a lock" "$(cat "$APT_CONF")" "DPkg::Lock::Timeout \"$FM_SIM_CLOUD_APT_LOCK_TIMEOUT\";"
assert_has "a second run changes nothing" "$(step 01-sim-cloud-host.sh install)" "already set"
assert_rc "an incomplete host.env fails the step" 1 env -u FM_TS_TAG PATH="$BIN:$SYS_PATH" bash "$FM_ROOT/scripts/steps/01-sim-cloud-host.sh" install
assert_rc "the test root needs FM_SIM_TEST=1" 1 env FM_SIM_TEST=0 PATH="$BIN:$SYS_PATH" bash "$FM_ROOT/scripts/steps/01-sim-cloud-host.sh" install

# --- sim-cloud-card ----------------------------------------------------------------

printf '\n── sim-cloud-card ──\n'
rc=0; out="$(step 11-sim-cloud-card.sh install)" || rc=$?
assert_eq "install exits 0" 0 "$rc"
assert_eq "the card names the host, the role, and the workload" "sim-cloud|sim-cloud|sim|/opt/fm" \
  "$(jq -r '[.name, .role, .workload, .workspace] | join("|")' "$FM_MACHINE_FILE")"
assert_eq "the agent's key segment follows" "sim_cloud" "$(fm_machine_namespace)"
assert_eq "the card writes no env file" "false" "$([ -e "$R/etc/fm-comms.env" ] && echo true || echo false)"
assert_has "a second run leaves the card" "$(step 11-sim-cloud-card.sh install)" "card already names"

# --- comms-bridge -------------------------------------------------------------------
#
# fm-comms upstream is a local repository holding the example env file and an
# install.sh stand-in that records how it was called and enables the unit the
# way fm-comms' bridge installer does.

printf '\n── comms-bridge ──\n'
COMMS_UP="$TMP/fm-comms-up"
mkdir -p "$COMMS_UP/systemd"
printf '# example\nFM_ROUTER_ENDPOINT=tcp/CHANGEME:7447\nFM_ROS_DOMAIN_ID=0\nROS_DOMAIN_ID=0\n' > "$COMMS_UP/systemd/fm-comms.env.example"
cat > "$COMMS_UP/install.sh" <<STUB
#!/usr/bin/env bash
printf 'fm-comms-install %s FM_YES=%s FM_ROUTER_ENDPOINT=%s FM_BRIDGE_PROFILE=%s FM_DDS_IFACE=%s workload=%s\n' "\$*" "\${FM_YES:-}" \
  "\${FM_ROUTER_ENDPOINT:-}" "\${FM_BRIDGE_PROFILE:-}" "\${FM_DDS_IFACE:-}" "\$(jq -r .workload "\$FM_MACHINE_FILE")" >> $LOG
[ "\${FAKE_COMMS:-ok}" = ok ] || exit 1
systemctl enable --now fm-zenoh-bridge.service
STUB
chmod 0755 "$COMMS_UP/install.sh"
git init --quiet "$COMMS_UP"
git -C "$COMMS_UP" config uploadpack.allowAnySHA1InWant true
git -C "$COMMS_UP" -c user.email=t@example.com -c user.name=t add -A
git -C "$COMMS_UP" -c user.email=t@example.com -c user.name=t commit --quiet -m init
COMMS_SHA="$(git -C "$COMMS_UP" rev-parse HEAD)"
bridge() { env FM_SIM_TEST_COMMS_SOURCE="file://$COMMS_UP" FM_SIM_TEST_COMMS_COMMIT="$COMMS_SHA" PATH="$BIN:$SYS_PATH" \
  bash "$FM_ROOT/scripts/steps/62-comms-bridge.sh" "$@" 2>&1; }

: > "$LOG"
rc=0; out="$(bridge install)" || rc=$?
assert_eq "install exits 0" 0 "$rc"
assert_eq "root's tree is the pinned commit" "$COMMS_SHA" "$(git -C "$R$FM_COMMS_ROOT" rev-parse HEAD)"
assert_has "  fetched with no inherited git config" "$(cat "$LOG")" "sudo env -i PATH=/usr/bin:/bin HOME=/nonexistent GIT_NO_REPLACE_OBJECTS=1"
comms="$(cat "$R/etc/fm-comms.env")"
assert_has "the env file starts from fm-comms' example" "$comms" "# example"
assert_has "  names the router" "$comms" "FM_ROUTER_ENDPOINT=tcp/fm-router:7447"
assert_lacks "  once" "$comms" "CHANGEME"
assert_has "  names the Jazzy graph" "$comms" "FM_ROS_DISTRO=jazzy"
assert_has "  names the image at its digest" "$comms" "FM_SIM_IMAGE=${FM_SIM_IMAGE%:*}@$DIGEST"
assert_has "  keeps the fleet's domain" "$comms" "FM_ROS_DOMAIN_ID=0"
assert_eq "  and is 644" 644 "$(stat -c '%a' "$R/etc/fm-comms.env")"
call="$(grep '^fm-comms-install' "$LOG")"
assert_has "fm-comms' own installer runs the bridge role, unattended" "$call" "install --role bridge FM_YES=1"
assert_has "  with the router from host.env" "$call" "FM_ROUTER_ENDPOINT=tcp/fm-router:7447"
assert_has "  with the profile left to the card (workload sim)" "$call" "FM_BRIDGE_PROFILE= FM_DDS_IFACE= workload=sim"
assert_has "the bridge unit is enabled" "$(cat "$LOG")" "systemctl enable --now $FM_COMMS_BRIDGE_UNIT"
: > "$LOG"
out="$(bridge install)"
assert_has "a second run fetches nothing" "$out" "already at $COMMS_SHA"
assert_has "  and leaves the env file" "$out" "fm-comms.env current"
rc=0; out="$(FAKE_DOWN="is-enabled --quiet $FM_COMMS_BRIDGE_UNIT" bridge install)" || rc=$?
assert_eq "a bridge left disabled fails the step" 1 "$rc"
assert_has "  and says so" "$out" "is not enabled after fm-comms' installer"
rc=0; out="$(FAKE_COMMS=fail bridge install)" || rc=$?
assert_eq "a failing fm-comms installer fails the step" 1 "$rc"
rm -rf "$R$FM_COMMS_ROOT"
rc=0; out="$(env FM_SIM_TEST_COMMS_SOURCE="file://$COMMS_UP" FM_SIM_TEST_COMMS_COMMIT="$(printf '%040d' 7)" \
  PATH="$BIN:$SYS_PATH" bash "$FM_ROOT/scripts/steps/62-comms-bridge.sh" install 2>&1)" || rc=$?
assert_eq "a pin upstream does not hold fails the step" 1 "$rc"
assert_eq "  and runs no installer" "false" "$([ -e "$R$FM_COMMS_ROOT/install.sh" ] && echo true || echo false)"
assert_rc "a test source without a test root is refused" 1 env -u FM_SIM_TEST_ROOT FM_SIM_TEST_COMMS_SOURCE=file:///x \
  PATH="$BIN:$SYS_PATH" bash "$FM_ROOT/scripts/steps/62-comms-bridge.sh" check
bridge install >/dev/null

# --- tailscale-authkey ----------------------------------------------------------------

printf '\n── tailscale-authkey ──\n'
keydirs() { find "$R/run" -mindepth 1 | wc -l; }
join_case() {  # label — run the step's install and capture everything it printed
  : > "$LOG"
  rc=0; out="$(step 61-tailscale-authkey.sh install)" || rc=$?
}

echo "NeedsLogin|" > "$TS_STATE"
join_case
assert_eq "joins: exits 0" 0 "$rc"
assert_has "  advertises the tag and the name" "$(cat "$LOG")" "--advertise-tags=tag:sim-cloud --hostname=sim-cloud"
assert_has "  reads the parameter it is told, decrypted, in its region" "$(cat "$LOG")" \
  "aws ssm get-parameter --region eu-west-1 --name /fm-sim/cloud-host/tailscale-auth-key --with-decryption"
assert_lacks "  turns on no Tailscale SSH" "$(cat "$LOG")" "--ssh"
assert_lacks "  the key is never in the output" "$out" "$KEY"
assert_lacks "  the key is never in any argv" "$(cat "$LOG")" "$KEY"
assert_has "  tailscale reads it from a file" "$(cat "$LOG")" "--auth-key=file:$R/run/fm-ts-key."
assert_eq "  the file was 600, its directory 700" "600|700" "$(cat "$TS_STATE.keymode")|$(cat "$TS_STATE.dirmode")"
assert_eq "  and both are gone" "false" "$([ -e "$(cat "$TS_STATE.keyfile")" ] && echo true || echo false)"
assert_eq "  nothing is left under /run" 0 "$(keydirs)"

join_case
assert_eq "already joined with the tag: exits 0" 0 "$rc"
assert_eq "  and reads no key" "" "$(grep '^aws' "$LOG" || true)"

echo "Running|tag:other" > "$TS_STATE"
join_case
assert_eq "joined without the tag: fails" 1 "$rc"

echo "NeedsLogin|" > "$TS_STATE"
FAKE_TS_GRANTED=tag:other join_case
assert_eq "a key that does not grant the tag: fails" 1 "$rc"
assert_lacks "  without printing the key" "$out" "$KEY"

echo "NeedsLogin|" > "$TS_STATE"
FAKE_TS_UP=fail join_case
assert_eq "a failed tailscale up: fails" 1 "$rc"
assert_lacks "  without printing the key" "$out" "$KEY"
assert_eq "  and leaves no key file" 0 "$(keydirs)"

echo "NeedsLogin|" > "$TS_STATE"
FAKE_AWS=malformed join_case
assert_eq "a parameter that holds no key: fails" 1 "$rc"
assert_has "  and says so" "$out" "does not hold a Tailscale auth key"
assert_lacks "  without printing the value" "$out" "$KEY"
assert_eq "  and never runs tailscale up" "" "$(grep '^tailscale up' "$LOG" || true)"
assert_eq "  and leaves no key file" 0 "$(keydirs)"

FAKE_AWS=fail join_case
assert_eq "an unreadable parameter: fails" 1 "$rc"
assert_has "  and passes on aws's reason" "$out" "ParameterNotFound"
assert_eq "  and leaves no key file" 0 "$(keydirs)"

# A run killed mid-join (the bootstrap's timeout sends TERM) still destroys the key.
echo "NeedsLogin|" > "$TS_STATE"
mv "$BIN/tailscale" "$BIN/tailscale.real"
# The hung `up` records its own pid, so the case can tell whether the trap ended it.
stub tailscale 'case "$1" in up) echo $$ > @TS@.uppid; exec sleep 37 ;; *) exec "$(dirname "$0")/tailscale.real" "$@" ;; esac'
rm -f "$TS_STATE.uppid"
env PATH="$BIN:$SYS_PATH" bash "$FM_ROOT/scripts/steps/61-tailscale-authkey.sh" install >/dev/null 2>&1 &
pid=$!
for _ in $(seq 50); do [ -n "$(find "$R/run" -name key 2>/dev/null)" ] && break; sleep 0.1; done
assert_eq "a key file exists while the join runs" 1 "$(find "$R/run" -name key | wc -l)"
for _ in $(seq 50); do [ -s "$TS_STATE.uppid" ] && break; sleep 0.1; done
start=$SECONDS
kill -TERM "$pid"; wait "$pid" 2>/dev/null || true
assert_eq "  and TERM leaves none" 0 "$(keydirs)"
assert_eq "  at once, not when tailscale up gives up" true "$([ $((SECONDS - start)) -lt 10 ] && echo true || echo false)"
assert_eq "  and ends the hung tailscale up" false \
  "$(kill -0 "$(cat "$TS_STATE.uppid")" 2>/dev/null && echo true || echo false)"
mv "$BIN/tailscale.real" "$BIN/tailscale"

# The whole role's output, as cloud-init would log it, through the join.
echo "NeedsLogin|" > "$TS_STATE"
rc=0; out="$(front --sim-cloud --only sim-cloud-host,tailscale-authkey)" || rc=$?
assert_eq "install.sh through the join exits 0" 0 "$rc"
assert_lacks "  and its output never holds the key" "$out" "$KEY"

# --- sim-cloud-ready ----------------------------------------------------------------

printf '\n── sim-cloud-ready ──\n'
echo "Running|tag:sim-cloud" > "$TS_STATE"
rc=0; out="$(step 92-sim-cloud-ready.sh install)" || rc=$?
assert_eq "a serving host passes" 0 "$rc"
assert_has "  and names its verbs" "$out" "serving fm/sim/sim_cloud/*"
not_ready() {  # label env…
  local label="$1"; shift
  local rc=0
  env "$@" PATH="$BIN:$SYS_PATH" bash "$FM_ROOT/scripts/steps/92-sim-cloud-ready.sh" install >/dev/null 2>&1 || rc=$?
  assert_eq "not ready: $label" 1 "$rc"
}
not_ready "docker down" FAKE_DOWN="is-active --quiet docker"
not_ready "no driver" FAKE_NVSMI=fail
not_ready "agent not enabled" FAKE_DOWN="is-enabled --quiet $FM_SIM_UNIT"
not_ready "agent not active" FAKE_DOWN="is-active --quiet $FM_SIM_UNIT"
not_ready "no docker grant" FAKE_GROUPS=fm-sim
echo "Running|tag:other" > "$TS_STATE"
not_ready "the wrong tag" FAKE_NVSMI=ok
echo "NeedsLogin|" > "$TS_STATE"
not_ready "not joined" FAKE_NVSMI=ok
echo "Running|tag:sim-cloud" > "$TS_STATE"
not_ready "bridge not enabled" FAKE_DOWN="is-enabled --quiet $FM_COMMS_BRIDGE_UNIT"
not_ready "bridge not active" FAKE_DOWN="is-active --quiet $FM_COMMS_BRIDGE_UNIT"
assert_rc "check always exits 0" 0 env PATH="$BIN:$SYS_PATH" bash "$FM_ROOT/scripts/steps/92-sim-cloud-ready.sh" check

# --- The other front doors --------------------------------------------------------

printf '\n── update and check ──\n'
HE="$TMP/host.env"
printf '%s\n' "${HOST_ENV[@]}" 'FM_EVIL=$(touch '"$TMP"'/evil)' > "$HE"
out="$(env -u FM_TS_TAG -u FM_ROUTER_ENDPOINT bash -c ". '$FM_ROOT/lib.sh'; . '$FM_ROOT/scripts/manifest.sh'
  . '$FM_ROOT/scripts/internal/sim-cloud-lib.sh'; sim_cloud_load_host_env '$HE'
  printf '%s|%s|%s\n' \"\$FM_TS_TAG\" \"\$FM_ROUTER_ENDPOINT\" \"\${FM_EVIL:-unset}\"")"
assert_eq "host.env is read for the variables the role needs" "tag:sim-cloud|tcp/fm-router:7447|unset" "$out"
assert_eq "  as data: nothing in it runs" false "$([ -e "$TMP/evil" ] && echo true || echo false)"
out="$(FM_TS_TAG=tag:kept bash -c ". '$FM_ROOT/lib.sh'; . '$FM_ROOT/scripts/manifest.sh'
  . '$FM_ROOT/scripts/internal/sim-cloud-lib.sh'; sim_cloud_load_host_env '$HE'; printf '%s' \"\$FM_TS_TAG\"")"
assert_eq "  and an exported value wins" tag:kept "$out"
out="$(env PATH="$BIN:$SYS_PATH" FM_NO_MODIFY_PATH=1 FM_ALLOW_OS_MISMATCH=1 bash "$FM_ROOT/scripts/update.sh" --check 2>&1 || true)"
assert_has "fm update converges a sim-cloud card with its role" "$out" "converging fm-setup (--sim-cloud, check)"
assert_lacks "  rather than refusing it" "$out" "unknown role"
out="$(env PATH="$BIN:$SYS_PATH" bash "$FM_ROOT/scripts/run/check.sh" --sim-cloud --only sim-cloud-ready 2>&1 || true)"
assert_has "check takes --sim-cloud" "$out" "fm-setup — sim-cloud [check]"
rc=0; FM_MACHINE_FILE="$TMP/other.json" bash "$FM_ROOT/scripts/run/machine.sh" init --name sim-cloud --role workstation >/dev/null 2>&1 || rc=$?
assert_eq "machine init refuses the name sim-cloud on another role" 2 "$rc"
assert_eq "  and writes no card" false "$([ -e "$TMP/other.json" ] && echo true || echo false)"

# --- Result ----------------------------------------------------------------

echo
if [ "$FAIL" -eq 0 ]; then
  fm_ok "$PASS passed"
else
  fm_err "$FAIL failed, $PASS passed"
  exit 1
fi
