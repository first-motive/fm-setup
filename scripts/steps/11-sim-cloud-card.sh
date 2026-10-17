#!/usr/bin/env bash
#
# sim-cloud-card — the cloud sim host's identity card.
#
# /etc/fm/machine.json, written from host.env by `machine init`, the card's one
# writer: name FM_MACHINE_NAME, role sim-cloud, workload sim. The agent serves
# fm/sim/<name with - as _>/*, and the workload selects fm-comms'
# bridge-sim.json5 when the comms-bridge step renders it. `machine init` also
# sets the hostname to the name.
#
# After base-deps, which installs the jq `machine init` needs, and before
# workspace, which reads the card for the workspace path.
#
# The card follows FM_MACHINE_FILE, as `machine init` does, which is how
# scripts/dev/test-sim-cloud.sh points it at a temp file.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$_here/../.." && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$FM_ROOT/lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$FM_ROOT/scripts/manifest.sh"
# shellcheck source=../internal/sim-cloud-lib.sh disable=SC1091
. "$FM_ROOT/scripts/internal/sim-cloud-lib.sh"

fm_require_linux

INIT_ARGS=(--name "${FM_MACHINE_NAME:-}" --role sim-cloud --workload sim)

card_current() {
  fm_machine_exists \
    && [ "$(fm_machine_get_opt name)" = "$FM_MACHINE_NAME" ] \
    && [ "$(fm_machine_get_opt role)" = sim-cloud ] \
    && [ "$(fm_machine_workload)" = sim ]
}

do_check() {
  if ! sim_cloud_env_ok 2>/dev/null; then
    fm_warn "host.env incomplete — run the sim-cloud-host step's check"
    return 0
  fi
  if card_current; then
    fm_ok "card names $FM_MACHINE_NAME, role sim-cloud, workload sim"
  else
    fm_warn "card missing or not $FM_MACHINE_NAME / sim-cloud / sim"
  fi
  return 0
}

do_install() {
  sim_cloud_env_ok || return 1
  if [ "${1:-}" = "--dry-run" ]; then
    fm_info "would run   machine init ${INIT_ARGS[*]}"
    return 0
  fi
  if card_current; then
    fm_ok "card already names $FM_MACHINE_NAME, role sim-cloud, workload sim"
    return 0
  fi
  bash "$FM_ROOT/scripts/run/machine.sh" init "${INIT_ARGS[@]}" || { fm_err "machine init failed"; return 1; }
}

do_uninstall() {
  # The card is the machine's identity, which every other step reads; removing
  # it is `machine reset`, a person's decision.
  fm_warn "the card is left in place — remove it deliberately with: fm machine reset"
}

fm_dispatch "$@"
