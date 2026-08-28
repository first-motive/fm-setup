#!/usr/bin/env bash
#
# nvidia-container — GPU passthrough into containers.
#
# Every GPU-reserving compose file in the stack needs this, so it gates
# annotation, training, and Isaac Sim alike, not just deployment.
#
# The four packages pin to one version and move in lockstep: an unpinned mix
# installs a runtime hook that does not match its library and containers fail to
# see the GPU. There is no binary called `nvidia-container-toolkit` — checking
# for one reports "command not found" on a working install, so check `nvidia-ctk`.
#
# Source: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$_here/../../lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$_here/../manifest.sh"

fm_require_linux

KEYRING=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
SOURCES=/etc/apt/sources.list.d/nvidia-container-toolkit.list

do_check() {
  if [ -f "$SOURCES" ]; then fm_ok "toolkit apt repo present"; else fm_warn "toolkit apt repo missing"; fi
  if fm_has_cmd nvidia-ctk; then
    fm_ok "nvidia-ctk $(nvidia-ctk --version 2>/dev/null | head -1)"
  else
    fm_warn "nvidia-ctk missing"
    return 0
  fi
  if fm_has_docker && grep -q nvidia /etc/docker/daemon.json 2>/dev/null; then
    fm_ok "docker runtime configured for nvidia"
  else
    fm_warn "docker runtime not configured for nvidia"
  fi
  return 0
}

add_repo() {
  fm_log "adding the NVIDIA container toolkit apt repo"
  # --batch --yes: a rerun after a mid-run failure finds the keyring already
  # there, and gpg's overwrite prompt would hang an unattended install (#31).
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | sudo gpg --batch --yes --dearmor -o "$KEYRING"
  # gpg exits 0 on empty input, so a truncated fetch would leave an empty
  # keyring here and apt would then trust an unverifiable repo.
  if ! sudo test -s "$KEYRING"; then
    sudo rm -f "$KEYRING"
    fm_err "the NVIDIA keyring came back empty — check the network and re-run"
    return 1
  fi
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed "s#deb https://#deb [signed-by=$KEYRING] https://#g" \
    | sudo tee "$SOURCES" >/dev/null
  sudo apt-get update
}

do_install() {
  [ -f "$SOURCES" ] || add_repo

  local p pinned=()
  for p in "${FM_NVIDIA_CONTAINER_APT[@]}"; do
    pinned+=("${p}=${FM_NVIDIA_CONTAINER_VERSION}")
  done

  # A pin means this version whatever is installed now. The distro archive can
  # seed a newer toolkit before this repo is added, and apt refuses to step
  # back without --allow-downgrades (#33). The hold then keeps unattended
  # upgrades from drifting the four packages apart again.
  fm_log "apt install ${pinned[*]}"
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades "${pinned[@]}"
  sudo apt-mark hold "${FM_NVIDIA_CONTAINER_APT[@]}" >/dev/null

  # Recorded rather than installed through fm_apt_install: this is the one step
  # that installs pinned "name=version" strings, which the helper's presence
  # check cannot read. The packages are named in the manifest, so what the
  # ledger must hold is known without diffing for it.
  fm_ledger_record nvidia-container "${FM_NVIDIA_CONTAINER_APT[@]}"

  fm_log "configuring the docker runtime"
  sudo nvidia-ctk runtime configure --runtime=docker
  sudo systemctl restart docker

  fm_ok "toolkit installed — verify with: docker run --rm --gpus all $FM_CUDA_SMOKE_IMAGE nvidia-smi"
}

do_uninstall() {
  local p installed=()
  for p in "${FM_NVIDIA_CONTAINER_APT[@]}"; do
    fm_has_pkg "$p" && installed+=("$p")
  done
  # The hold comes off first: apt refuses to remove a held package, and the
  # ledger's own refusal must be the one that stops this, not a stale hold.
  if [ "${#installed[@]}" -gt 0 ]; then
    sudo apt-mark unhold "${installed[@]}" >/dev/null
  fi
  fm_apt_uninstall nvidia-container || return 1
  sudo rm -f "$SOURCES" "$KEYRING"
  fm_warn "/etc/docker/daemon.json still names the nvidia runtime — edit it before restarting docker"
}

fm_dispatch "$@"
