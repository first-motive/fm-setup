#!/usr/bin/env bash
#
# sim-cloud-lib.sh — the sim-cloud role's pure checks, sourced by install.sh
# for that role, by its steps, and tested directly by
# scripts/dev/test-sim-cloud.sh.
#
# Nothing here changes the host. Each function judges what it is given, or the
# environment host.env was exported into, and answers with a return code and a
# message that names the variable, so a refusal in cloud-init's log says which
# line of host.env to fix.
#
# Requires lib.sh (fm_err, fm_machine_valid_name) and scripts/manifest.sh
# (FM_SIM_CLOUD_REQUIRED_ENV) to be sourced first.

# _sim_cloud_match NAME VALUE ERE WANT — 0 when VALUE matches ERE; otherwise
# name the variable and the shape it must have.
_sim_cloud_match() {
  # grep matches line by line, so a value with a newline in it is refused
  # first: one good line would otherwise carry the rest into /etc/fm-comms.env.
  case "$2" in *$'\n'*) fm_err "$1 holds a newline — refusing"; return 1 ;; esac
  printf '%s' "$2" | grep -Eq "$3" && return 0
  fm_err "$1 is malformed: '$2' (want $4)"
  return 1
}

# sim_cloud_env_ok — 0 when every variable the role needs is set and shaped as
# the stack writes it. Checks them all before answering, so one run names every
# line of host.env that is wrong.
sim_cloud_env_ok() {
  local var bad=0
  for var in "${FM_SIM_CLOUD_REQUIRED_ENV[@]}"; do
    if [ -z "${!var:-}" ]; then
      fm_err "$var is not set — the sim-cloud role reads it from $FM_SIM_CLOUD_HOST_ENV"
      bad=1
    fi
  done
  [ "$bad" = 0 ] || return 1

  fm_machine_valid_name "$FM_MACHINE_NAME" sim-cloud || bad=1
  _sim_cloud_match FM_SETUP_SHA "$FM_SETUP_SHA" '^[0-9a-f]{40}$' "a full 40-character SHA" || bad=1
  _sim_cloud_match FM_SIM_COMMIT "$FM_SIM_COMMIT" '^[0-9a-f]{40}$' "a full 40-character SHA" || bad=1
  _sim_cloud_match FM_SIM_IMAGE_DIGEST "$FM_SIM_IMAGE_DIGEST" '^sha256:[0-9a-f]{64}$' "sha256:<64 hex>" || bad=1
  _sim_cloud_match FM_ROUTER_ENDPOINT "$FM_ROUTER_ENDPOINT" '^tcp/[A-Za-z0-9.-]+:7447$' "tcp/<router>:7447" || bad=1
  _sim_cloud_match FM_TS_AUTHKEY_SSM_PARAMETER "$FM_TS_AUTHKEY_SSM_PARAMETER" '^(/[A-Za-z0-9_.-]+)+$' "an SSM parameter name" || bad=1
  _sim_cloud_match FM_TS_TAG "$FM_TS_TAG" '^tag:[a-z0-9-]+$' "tag:<name>" || bad=1
  _sim_cloud_match FM_SIM_CLOUD_REGION "$FM_SIM_CLOUD_REGION" '^[a-z]{2}(-[a-z]+)+-[0-9]+$' "an AWS region" || bad=1
  [ "$bad" = 0 ]
}

# sim_cloud_setup_sha_ok DIR — 0 when the fm-setup checkout at DIR is at
# FM_SETUP_SHA. The bootstrap checks the same thing after its fetch; this is the
# role refusing to run from a tree that has moved since.
sim_cloud_setup_sha_ok() {
  local dir="$1" head
  head="$(git -C "$dir" rev-parse HEAD 2>/dev/null)" || {
    fm_err "$dir is not a git checkout — cannot check it against FM_SETUP_SHA"
    return 1
  }
  [ "$head" = "$FM_SETUP_SHA" ] && return 0
  fm_err "this checkout is at $head, not FM_SETUP_SHA $FM_SETUP_SHA — refusing to provision from it"
  return 1
}

# sim_cloud_preflight DIR — everything the role checks before a step runs.
sim_cloud_preflight() {
  sim_cloud_env_ok || return 1
  sim_cloud_setup_sha_ok "$1"
}

# sim_cloud_load_host_env [FILE] — export host.env's required variables, for a
# caller that did not get them from the bootstrap (`fm update` on the host).
#
# Read as data, never sourced: only KEY=value lines whose KEY the role requires,
# and only for a variable the environment does not already set.
sim_cloud_load_host_env() {
  local file="${1:-$FM_SIM_CLOUD_HOST_ENV}" key value
  [ -f "$file" ] || return 0
  while IFS='=' read -r key value; do
    _fm_in_list "$key" "${FM_SIM_CLOUD_REQUIRED_ENV[@]}" || continue
    [ -z "${!key:-}" ] || continue
    printf -v "$key" '%s' "$value"
    export "${key?}"
  done < <(grep -E '^[A-Z_]+=' "$file")
}

# sim_cloud_has_tag TAG — 0 when this node is joined and carries TAG.
sim_cloud_has_tag() {
  tailscale status --json --peers=false 2>/dev/null \
    | jq -e --arg t "$1" '.BackendState == "Running" and ((.Self.Tags // []) | index($t) != null)' >/dev/null 2>&1
}

# sim_cloud_set_key TEXT KEY VALUE — echo TEXT with KEY's assignment replaced by
# KEY=VALUE, every other line left as it was. The same edit fm-comms-set makes,
# so a key fm-comms later adds to the file survives a re-run of this role.
sim_cloud_set_key() {
  local text="$1" key="$2" value="$3"
  [ -z "$text" ] || printf '%s\n' "$text" | grep -v "^${key}=" || true
  printf '%s=%s\n' "$key" "$value"
}
