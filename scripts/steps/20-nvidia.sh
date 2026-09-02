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

# No `grep -q`: quitting early sends lspci SIGPIPE, and under pipefail the
# pipeline then reports 141 — a present GPU read as absent.
has_gpu() { lspci 2>/dev/null | grep -i nvidia >/dev/null; }

driver_loaded() { fm_has_cmd nvidia-smi && nvidia-smi >/dev/null 2>&1; }

# The dkms package a host converged on before the signed in-tree module was
# pinned. While it is installed, depmod ranks its unsigned build above the
# signed one, so the signed package can be present and the GPU still gone.
# `dpkg -s` also answers for a removed package whose config files remain, so
# ask for the install state itself.
DKMS_PACKAGE=nvidia-dkms-580-open
dkms_installed() {
  [ "$(dpkg-query -W -f='${Status}' "$DKMS_PACKAGE" 2>/dev/null)" = "install ok installed" ]
}

# The loaded module's path is the evidence that the signed package won: the
# in-tree build lives under kernel/, a dkms build under updates/dkms/.
module_path() { modinfo -n nvidia 2>/dev/null || true; }

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
  # The `-generic` suffix is the running kernel's flavour. An HWE or lowlatency
  # kernel needs a different package, and apt would only say so mid-install.
  local candidate
  candidate="$(apt-cache policy "${FM_NVIDIA_APT[0]}" 2>/dev/null | sed -n 's/^ *Candidate: //p')"
  case "$candidate" in
    ""|"(none)") fm_warn "${FM_NVIDIA_APT[0]} has no apt candidate for kernel $(uname -r)" ;;
  esac
  if dkms_installed; then
    fm_warn "$DKMS_PACKAGE still installed — its unsigned module outranks the signed one; run install"
  fi
  case "$(module_path)" in
    "") ;;
    */updates/dkms/*) fm_warn "loaded module is the dkms build: $(module_path)" ;;
    *) fm_ok "loaded module is the signed in-tree build" ;;
  esac
  return 0
}

do_install() {
  if ! has_gpu; then
    fm_warn "no NVIDIA GPU detected — nothing to install"
    return 0
  fi

  fm_apt_install nvidia "${FM_NVIDIA_APT[@]}"

  # A host that converged before the signed module was pinned still carries
  # the dkms package, and installing the signed one beside it repairs nothing:
  # depmod keeps loading the dkms build. Removing only that package leaves the
  # driver metapackage in place; the signed module takes over at the next boot.
  if dkms_installed; then
    fm_log "removing $DKMS_PACKAGE so the signed module loads"
    sudo DEBIAN_FRONTEND=noninteractive apt-get remove -y "$DKMS_PACKAGE"
    fm_warn "reboot required before the signed module loads — run 'sudo reboot', then re-run this step's check"
    return 0
  fi

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
