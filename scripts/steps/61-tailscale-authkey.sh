#!/usr/bin/env bash
#
# tailscale-authkey — join the tailnet unattended, with an auth key read from SSM.
#
# The tailscale step installs the daemon and, on a host somebody sits at, joins
# interactively. A cloud sim host has nobody at it, so this step joins with the
# auth key the stack keeps in a SecureString parameter (FM_TS_AUTHKEY_SSM_PARAMETER,
# read in FM_SIM_CLOUD_REGION through the instance role), advertising
# FM_TS_TAG and named FM_MACHINE_NAME.
#
# The key must be an ephemeral, pre-authorised key that grants FM_TS_TAG: the
# tailnet then drops the node on its own once the instance is gone, and the
# tag is what the tailnet ACL grants (templates/tailscale/sim-cloud-acl.hujson,
# which the operator applies — no step can change the tailnet's policy).
#
# The key is a credential, and cloud-init copies this run's output to the
# instance's console log, so it never reaches stdout, stderr, argv, or a file
# anything else reads:
#
#   - aws writes it straight into a 0600 file in a 0700 directory under /run,
#     a tmpfs, so it never touches the disk;
#   - tailscale reads it from that file (`--auth-key=file:<path>`), so argv
#     holds only the path;
#   - the file is shredded and the directory removed whether the join worked
#     or not;
#   - its shape is checked without printing it, and no message names it.
#
# Test hook, for scripts/dev/test-sim-cloud.sh only: FM_SIM_TEST=1 with
# FM_SIM_TEST_ROOT (under the temp directory) prefixes /run.

set -euo pipefail
set +x

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$_here/../.." && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$FM_ROOT/lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$FM_ROOT/scripts/manifest.sh"
# shellcheck source=../internal/sim-lib.sh disable=SC1091
. "$FM_ROOT/scripts/internal/sim-lib.sh"
# shellcheck source=../internal/sim-cloud-lib.sh disable=SC1091
. "$FM_ROOT/scripts/internal/sim-cloud-lib.sh"

fm_require_linux

R="${FM_SIM_TEST_ROOT:-}"
if [ -n "$R" ]; then sim_test_root_ok "$R" || exit 1; fi

# How long `tailscale up` may take to authenticate before the step fails.
UP_TIMEOUT=180s

# Echo the daemon's state ("Running" once joined), or nothing.
backend_state() { tailscale status --json --peers=false 2>/dev/null | jq -r '.BackendState // empty' 2>/dev/null || true; }

has_tag() { sim_cloud_has_tag "$FM_TS_TAG"; }

do_check() {
  if ! fm_has_cmd tailscale; then
    fm_warn "tailscale missing — the tailscale step installs it"
    return 0
  fi
  if [ "$(backend_state)" != Running ]; then
    fm_warn "not joined to a tailnet"
    return 0
  fi
  fm_ok "joined"
  if [ -n "${FM_TS_TAG:-}" ] && has_tag; then
    fm_ok "node carries $FM_TS_TAG"
  else
    fm_warn "node does not carry ${FM_TS_TAG:-the FM_TS_TAG tag}"
  fi
  return 0
}

# Read the key into FILE. Nothing the key passes through is printed.
read_key() {
  local file="$1" err="$2"
  if ! aws ssm get-parameter --region "$FM_SIM_CLOUD_REGION" --name "$FM_TS_AUTHKEY_SSM_PARAMETER" \
       --with-decryption --query Parameter.Value --output text >"$file" 2>"$err"; then
    # aws reports why it could not read the parameter, never its value.
    fm_err "could not read $FM_TS_AUTHKEY_SSM_PARAMETER in $FM_SIM_CLOUD_REGION:"
    sed 's/^/        /' "$err" >&2
    return 1
  fi
  # An auth key or an OAuth client secret, with the client secret's query
  # options. Checked in place: grep -q prints nothing.
  if [ "$(wc -l <"$file")" -gt 1 ] || ! grep -Eqx 'tskey-[A-Za-z0-9_-]+(\?[A-Za-z0-9=&_-]+)?' "$file"; then
    fm_err "$FM_TS_AUTHKEY_SSM_PARAMETER does not hold a Tailscale auth key (want tskey-…; the value is not shown)"
    return 1
  fi
}

join() {
  local dir="$1"
  read_key "$dir/key" "$dir/aws.err" || return 1
  fm_log "joining the tailnet as $FM_MACHINE_NAME with $FM_TS_TAG"
  # In the background and waited for, so a TERM during the join reaches the
  # trap at once and the key is shredded then, not when `up` gives up.
  local pid rc=0
  sudo tailscale up --reset --auth-key="file:$dir/key" --advertise-tags="$FM_TS_TAG" \
    --hostname="$FM_MACHINE_NAME" --timeout="$UP_TIMEOUT" &
  pid=$!
  UP_PID="$pid"
  wait "$pid" || rc=$?
  UP_PID=""
  [ "$rc" = 0 ] || { fm_err "tailscale up failed"; return 1; }
}

# The key directory while it exists, and a running `tailscale up`, for the
# cleanup a signal also runs.
KEY_DIR=""
UP_PID=""

destroy_key() {
  [ -z "$UP_PID" ] || kill "$UP_PID" 2>/dev/null || true
  [ -n "$KEY_DIR" ] || return 0
  if [ -f "$KEY_DIR/key" ]; then
    if fm_has_cmd shred; then shred -u "$KEY_DIR/key" 2>/dev/null || rm -f "$KEY_DIR/key"; else rm -f "$KEY_DIR/key"; fi
  fi
  rm -rf "$KEY_DIR"
  KEY_DIR=""
}

# The key file's whole life: made, used, and destroyed here — and destroyed on
# a signal too, since the bootstrap's timeout ends a hung run with one.
join_with_key() {
  local rc=0
  trap 'destroy_key; exit 1' INT TERM HUP
  trap destroy_key EXIT
  KEY_DIR="$(umask 077 && mktemp -d "$R/run/fm-ts-key.XXXXXX")" || { fm_err "creating a key directory under /run failed"; return 1; }
  umask 077
  join "$KEY_DIR" || rc=$?
  destroy_key
  return "$rc"
}

do_install() {
  sim_cloud_env_ok || return 1
  if [ "${1:-}" = "--dry-run" ]; then
    fm_info "would read  $FM_TS_AUTHKEY_SSM_PARAMETER in $FM_SIM_CLOUD_REGION into a 0600 file under /run"
    fm_info "would run   tailscale up --reset --auth-key=file:<that file> --advertise-tags=$FM_TS_TAG --hostname=$FM_MACHINE_NAME"
    fm_info "would shred the file"
    return 0
  fi
  fm_has_cmd tailscale || { fm_err "tailscale missing — run the tailscale step first"; return 1; }

  if [ "$(backend_state)" = Running ]; then
    has_tag || { fm_err "already joined, but not as $FM_TS_TAG — log out (sudo tailscale logout) and re-run"; return 1; }
    fm_ok "already joined as $FM_TS_TAG"
    return 0
  fi

  fm_has_cmd aws || { fm_err "no aws CLI — the auth key is read with it"; return 1; }
  join_with_key || return 1
  has_tag || { fm_err "joined, but the node does not carry $FM_TS_TAG — the key must grant it"; return 1; }
  fm_ok "joined as $FM_MACHINE_NAME with $FM_TS_TAG"
}

do_uninstall() {
  if fm_has_cmd tailscale && [ "$(backend_state)" = Running ]; then
    sudo tailscale logout || { fm_err "tailscale logout failed — remove the node in the admin console"; return 1; }
    fm_ok "logged out of the tailnet"
  else
    fm_skip "not joined"
  fi
}

fm_dispatch "$@"
