#!/usr/bin/env bash
#
# system-update — apt update + upgrade. Never reboots; a kernel change is left
# for the operator to schedule.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$_here/../../lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$_here/../manifest.sh"

fm_require_linux

do_check() {
  local pending
  pending="$(apt list --upgradable 2>/dev/null | grep -c upgradable || true)"
  if [ "$pending" -gt 0 ]; then
    fm_info "$pending package(s) upgradable"
  else
    fm_ok "no pending upgrades"
  fi
  [ -f /var/run/reboot-required ] && fm_warn "reboot pending from an earlier upgrade"
  return 0
}

do_install() {
  fm_log "apt update && apt upgrade"
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
  fm_ok "system updated"

  if [ -f /var/run/reboot-required ]; then
    fm_warn "reboot required — run 'sudo reboot' once the run finishes"
  fi
}

do_uninstall() {
  fm_warn "a system upgrade is not reversible — packages left in place"
  return 0
}

fm_dispatch "$@"
