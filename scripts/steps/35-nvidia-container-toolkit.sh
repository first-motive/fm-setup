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
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | sudo gpg --dearmor -o "$KEYRING"
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

  fm_log "apt install ${pinned[*]}"
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${pinned[@]}"

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
  if [ "${#installed[@]}" -gt 0 ]; then
    fm_log "apt remove ${installed[*]}"
    sudo apt-get remove -y "${installed[@]}"
  fi
  sudo rm -f "$SOURCES" "$KEYRING"
  fm_warn "/etc/docker/daemon.json still names the nvidia runtime — edit it before restarting docker"
}

fm_dispatch "$@"
