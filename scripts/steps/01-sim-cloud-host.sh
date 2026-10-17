#!/usr/bin/env bash
#
# sim-cloud-host — check host.env, and make apt wait for a lock rather than fail.
#
# The sim-cloud role runs unattended from fm-sim's AWS stack bootstrap, which
# exports /etc/fm-sim-cloud/host.env before it runs install.sh. install.sh
# refuses the role before any step runs when that environment is incomplete or
# this checkout is not at FM_SETUP_SHA; this step repeats the check so that
# `--only` runs hold to it too.
#
# A fresh instance runs apt-daily and unattended-upgrades on its first boot,
# during the same minutes the bootstrap runs this role, and apt's default is to
# fail on a held lock at once. One apt.conf.d drop-in makes every later apt call
# wait up to FM_SIM_CLOUD_APT_LOCK_TIMEOUT seconds instead.
#
# Test hook, for scripts/dev/test-sim-cloud.sh only: FM_SIM_TEST=1 with
# FM_SIM_TEST_ROOT (under the temp directory) prefixes the path this step writes.

set -euo pipefail

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

APT_CONF=/etc/apt/apt.conf.d/90fm-lock-timeout
APT_TEXT="// Written by fm-setup's sim-cloud-host step. Re-run the step rather than editing this file.
DPkg::Lock::Timeout \"$FM_SIM_CLOUD_APT_LOCK_TIMEOUT\";"

do_check() {
  if sim_cloud_preflight "$FM_ROOT"; then
    fm_ok "host.env complete; checkout at FM_SETUP_SHA"
  else
    fm_warn "host.env incomplete or checkout not at FM_SETUP_SHA (see above)"
  fi
  if [ -f "$R$APT_CONF" ] && [ "$(cat "$R$APT_CONF")" = "$APT_TEXT" ]; then
    fm_ok "apt waits ${FM_SIM_CLOUD_APT_LOCK_TIMEOUT}s for a lock"
  else
    fm_warn "$APT_CONF missing or out of date"
  fi
  return 0
}

do_install() {
  sim_cloud_preflight "$FM_ROOT" || return 1
  if [ "${1:-}" = "--dry-run" ]; then
    fm_info "would write $APT_CONF (DPkg::Lock::Timeout $FM_SIM_CLOUD_APT_LOCK_TIMEOUT)"
    return 0
  fi
  if [ -f "$R$APT_CONF" ] && [ "$(cat "$R$APT_CONF")" = "$APT_TEXT" ]; then
    fm_ok "apt lock timeout already set"
    return 0
  fi
  sudo install -d -m 0755 "$(dirname "$R$APT_CONF")" || { fm_err "creating $(dirname "$APT_CONF") failed"; return 1; }
  printf '%s\n' "$APT_TEXT" | sudo tee "$R$APT_CONF" >/dev/null || { fm_err "writing $APT_CONF failed"; return 1; }
  sudo chmod 0644 "$R$APT_CONF" || { fm_err "setting $APT_CONF's mode failed"; return 1; }
  fm_ok "apt waits ${FM_SIM_CLOUD_APT_LOCK_TIMEOUT}s for a lock"
}

do_uninstall() {
  if [ -f "$R$APT_CONF" ]; then
    sudo rm -f "$R$APT_CONF" || { fm_err "removing $APT_CONF failed"; return 1; }
    fm_ok "$APT_CONF removed"
  else
    fm_skip "$APT_CONF not present"
  fi
}

fm_dispatch "$@"
