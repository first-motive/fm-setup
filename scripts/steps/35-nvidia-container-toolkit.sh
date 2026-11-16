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
# A JetPack host is the exception. JetPack's own apt repo carries the toolkit
# and nvidia-jetpack-runtime depends on it, so there the step takes JetPack's
# packages, adds no repo, pins and holds nothing, and only points docker at the
# runtime. GitHub's pin would move JetPack's packages out from under it.
#
# Source: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$_here/../../lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$_here/../manifest.sh"

fm_require_linux

# Overridable for the reason FM_DEVICE_TREE is: the fingerprint check below is
# what stands between this machine and four packages installed as root off a
# downloaded key, and a test that cannot write to /usr/share or /etc can only
# ever assert that check on a host it is allowed to provision.
KEYRING="${FM_NVIDIA_KEYRING:-/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg}"
SOURCES="${FM_NVIDIA_SOURCES:-/etc/apt/sources.list.d/nvidia-container-toolkit.list}"

# is_jetpack — 0 on a JetPack rootfs, whose own repo serves the toolkit.
is_jetpack() { fm_has_pkg "$FM_JETPACK_MARKER_PKG"; }

# configure_docker_runtime — register the nvidia runtime in daemon.json and
# restart docker so it reads it. Shared by both sources of the toolkit.
configure_docker_runtime() {
  fm_log "configuring the docker runtime"
  sudo nvidia-ctk runtime configure --runtime=docker
  sudo systemctl restart docker
}

do_check() {
  if is_jetpack; then
    fm_ok "JetPack host — toolkit from JetPack's apt repo"
  elif [ -f "$SOURCES" ]; then
    fm_ok "toolkit apt repo present"
  else
    fm_warn "toolkit apt repo missing"
  fi
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

  # The key is checked by fingerprint, not taken on TLS alone: it signs the four
  # packages this step installs as root, and a repo signed by the wrong key
  # installs whatever it likes. `sudo gpg` because the keyring is root's.
  local fpr
  fpr="$(sudo gpg --show-keys --with-colons "$KEYRING" 2>/dev/null | awk -F: '/^fpr:/ { print $10; exit }')"
  if [ "$fpr" != "$FM_NVIDIA_KEY_FPR" ]; then
    fm_err "NVIDIA signing key fingerprint mismatch"
    fm_err "  expected $FM_NVIDIA_KEY_FPR"
    fm_err "  actual   ${fpr:-<unreadable>}"
    fm_err "  if NVIDIA rotated the key, re-derive the fingerprint and update"
    fm_err "  FM_NVIDIA_KEY_FPR in scripts/manifest.sh — do not bypass this check"
    sudo rm -f "$KEYRING"
    return 1
  fi
  fm_ok "signing key matches the pinned fingerprint"

  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed "s#deb https://#deb [signed-by=$KEYRING] https://#g" \
    | sudo tee "$SOURCES" >/dev/null
  sudo apt-get update
}

# install_jetpack — use JetPack's toolkit, installing its meta package only when
# the image left it out.
#
# A toolkit the vendor's image shipped belongs to the image, so neither its
# binary nor its meta package is handed to fm_apt_install, whose claim of a
# present package would let uninstall reach it. The robot role's baseline is
# the second guard. Only a toolkit this step installed lands in the ledger.
install_jetpack() {
  if fm_has_cmd nvidia-ctk || fm_has_pkg "$FM_JETPACK_CONTAINER_APT"; then
    fm_ok "JetPack's toolkit present ($(nvidia-ctk --version 2>/dev/null | head -1))"
  else
    fm_apt_install nvidia-container "$FM_JETPACK_CONTAINER_APT"
  fi
  configure_docker_runtime
  fm_ok "runtime configured — verify with: docker info --format '{{json .Runtimes}}' | grep nvidia"
}

do_install() {
  if is_jetpack; then
    install_jetpack
    return
  fi

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

  configure_docker_runtime

  fm_ok "toolkit installed — verify with: docker run --rm --gpus all $FM_CUDA_SMOKE_IMAGE nvidia-smi"
}

do_uninstall() {
  # Nothing was pinned or held on JetPack, and no repo was added, so the ledger
  # is all there is to reverse.
  if is_jetpack; then
    fm_apt_uninstall nvidia-container || return 1
    fm_warn "/etc/docker/daemon.json still names the nvidia runtime — edit it before restarting docker"
    return 0
  fi

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
