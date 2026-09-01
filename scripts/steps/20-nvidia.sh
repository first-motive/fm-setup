#!/usr/bin/env bash
#
# nvidia — the GPU driver on the workstation.
#
# The driver version is pinned in the manifest, not left to
# `ubuntu-drivers autoinstall`: Isaac Sim tracks driver branches and a too-new
# driver fails to start rather than degrading. Loading a new driver needs a
# reboot, which this step reports and never performs.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$_here/../../lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$_here/../manifest.sh"

fm_require_linux

has_gpu() { lspci 2>/dev/null | grep -qi nvidia; }

driver_loaded() { fm_has_cmd nvidia-smi && nvidia-smi >/dev/null 2>&1; }

do_check() {
  local package
  if ! has_gpu; then
    fm_info "no NVIDIA GPU on this machine"
    return 0
  fi
  if driver_loaded; then
    fm_ok "driver loaded: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)"
  else
    fm_warn "NVIDIA GPU present, no driver loaded"
  fi
  for package in "${FM_NVIDIA_APT[@]}"; do
    if fm_has_pkg "$package"; then
      fm_ok "$package installed"
    else
      fm_warn "$package missing"
    fi
  done
  return 0
}

do_install() {
  if ! has_gpu; then
    fm_warn "no NVIDIA GPU detected — nothing to install"
    return 0
  fi

  fm_apt_install nvidia "${FM_NVIDIA_APT[@]}"

  if driver_loaded; then
    fm_ok "driver loaded: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)"
  else
    fm_warn "reboot required before the driver loads — run 'sudo reboot', then re-run this step's check"
  fi
}

do_uninstall() {
  fm_warn "removing the GPU driver can leave the machine without a display — left in place"
  fm_info "remove it deliberately with: sudo apt-get remove --purge ${FM_NVIDIA_APT[*]}"
  return 0
}

fm_dispatch "$@"
