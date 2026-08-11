#!/usr/bin/env bash
#
# dds-tuning — kernel receive buffers for CycloneDDS.
#
# CycloneDDS asks for a 128 MB socket receive buffer. Ubuntu defaults to roughly
# 416 KB and CycloneDDS treats the shortfall as fatal:
#
#   failed to increase socket receive buffer size to at least 134217728 bytes,
#   current is 425984 bytes
#   [ERROR] rmw_create_node: failed to create domain, error Error
#
# Persisted as a sysctl drop-in, not `sysctl -w`: a reboot silently reverting the
# runtime value looks exactly like a network fault, and costs an afternoon.
#
# Both machines need it — the workstation and the Jetson are two ends of one
# DDS domain.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$_here/../../lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$_here/../manifest.sh"

fm_require_linux

DROPIN=/etc/sysctl.d/60-cyclonedds.conf

do_check() {
  if [ -f "$DROPIN" ]; then
    fm_ok "$DROPIN present"
  else
    fm_warn "$DROPIN missing"
  fi
  local current
  current="$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)"
  if [ "$current" -ge "$FM_DDS_RMEM_MAX" ]; then
    fm_ok "net.core.rmem_max = $current"
  else
    fm_warn "net.core.rmem_max = $current, want $FM_DDS_RMEM_MAX"
  fi
  return 0
}

do_install() {
  fm_log "writing $DROPIN"
  sudo tee "$DROPIN" >/dev/null <<EOF
# Managed by fm-setup. CycloneDDS needs a 128 MB socket receive buffer.
net.core.rmem_max=$FM_DDS_RMEM_MAX
net.core.rmem_default=$FM_DDS_RMEM_MAX
EOF
  sudo sysctl --system >/dev/null
  fm_ok "net.core.rmem_max = $(sysctl -n net.core.rmem_max)"
}

do_uninstall() {
  if [ -f "$DROPIN" ]; then
    sudo rm -f "$DROPIN"
    sudo sysctl --system >/dev/null
    fm_ok "$DROPIN removed"
  else
    fm_skip "$DROPIN not present"
  fi
}

fm_dispatch "$@"
