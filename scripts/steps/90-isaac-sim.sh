#!/usr/bin/env bash
#
# isaac-sim — pull the Isaac Sim container and prove the GPU reaches it.
#
# Containerised on purpose: NVIDIA ships native Isaac Sim for 22.04 and 24.04
# only, and this workstation runs 26.04. The container carries its own userspace
# and needs nothing from the host but the driver and the container toolkit.
#
# The image lives on NGC, which requires a login. This step will not invent
# credentials: with no login it prints what to run and stops, rather than
# failing halfway through a 20 GB pull.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$_here/../../lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$_here/../manifest.sh"

fm_require_linux

image_present() { docker image inspect "$FM_ISAAC_IMAGE" >/dev/null 2>&1; }

# NGC is a private registry: a pull without a login fails on authentication.
#
# Best-effort only — this sees that a login was recorded, not that the key is
# still valid. A revoked key passes this and fails at the pull instead, which is
# loud enough to diagnose.
logged_in_to_ngc() {
  [ -f "$HOME/.docker/config.json" ] && grep -q "nvcr.io" "$HOME/.docker/config.json" 2>/dev/null
}

do_check() {
  if ! fm_has_docker; then
    fm_warn "docker not reachable — install the docker step first"
    return 0
  fi

  if image_present; then
    fm_ok "$FM_ISAAC_IMAGE pulled"
  else
    fm_warn "$FM_ISAAC_IMAGE not pulled"
  fi

  if logged_in_to_ngc; then
    fm_ok "logged in to nvcr.io"
  else
    fm_warn "not logged in to nvcr.io"
  fi

  if [ -d "$FM_ISAAC_CACHE_DIR" ]; then
    fm_ok "$FM_ISAAC_CACHE_DIR present"
  else
    fm_warn "$FM_ISAAC_CACHE_DIR missing"
  fi

  if docker run --rm --gpus all "$FM_CUDA_SMOKE_IMAGE" nvidia-smi >/dev/null 2>&1; then
    fm_ok "the GPU is visible inside containers"
  else
    fm_warn "the GPU is not visible inside containers — check the nvidia-container step"
  fi
  return 0
}

# The GPU has to be visible from inside a container, not merely present on the
# host. This is the cheapest thing that proves the driver, the container
# toolkit, and the runtime hook all line up — and it fails loudly rather than
# leaving Isaac Sim to fail obscurely much later.
gpu_smoke_test() {
  fm_log "GPU smoke test: nvidia-smi inside a container"
  if docker run --rm --gpus all "$FM_CUDA_SMOKE_IMAGE" nvidia-smi >/dev/null 2>&1; then
    fm_ok "the GPU is visible inside containers"
    return 0
  fi
  fm_err "the GPU is not visible inside containers"
  fm_info "check the nvidia-container step, then: docker run --rm --gpus all $FM_CUDA_SMOKE_IMAGE nvidia-smi"
  return 1
}

do_install() {
  fm_has_docker || { fm_err "docker is not reachable — run the docker step first"; return 1; }

  # Isaac Sim cannot run without the GPU reaching the container, so a failed
  # smoke test stops this step — but only this step. It reports and returns
  # rather than aborting the provisioning run, because pulling a 20 GB image for
  # a stack that cannot start would be the wasteful half of the two.
  if ! gpu_smoke_test; then
    fm_warn "skipping Isaac Sim until the GPU reaches containers — fix that, then: ./install.sh --only isaac-sim"
    return 0
  fi

  # Isaac Sim writes its shader cache, asset cache, and logs to these paths.
  # Mounted from the host, they survive a container restart — a cold shader
  # cache costs minutes on every launch.
  fm_log "creating the Isaac Sim cache directories"
  # Only the host side matters here; the launch wrapper reads the container path
  # from the same entries when it builds the mount flags.
  local entry sub
  for entry in "${FM_ISAAC_CACHE_MAP[@]}"; do
    sub="${entry%%|*}"
    mkdir -p "$FM_ISAAC_CACHE_DIR/$sub"
  done
  fm_ok "$FM_ISAAC_CACHE_DIR ready"

  if image_present; then
    fm_ok "$FM_ISAAC_IMAGE already pulled"
    return 0
  fi

  if ! logged_in_to_ngc; then
    cat <<EOF

    Isaac Sim's image is on NGC and needs a login before it can be pulled:

      1. Generate an API key at https://ngc.nvidia.com/setup/api-key
      2. docker login nvcr.io      (username: \$oauthtoken, password: the key)
      3. re-run: ./install.sh --only isaac-sim

EOF
    fm_warn "not logged in to nvcr.io — skipping the pull"
    return 0
  fi

  fm_log "pulling $FM_ISAAC_IMAGE (this is a large image)"
  docker pull "$FM_ISAAC_IMAGE"
  fm_ok "Isaac Sim pulled — launch it with: ./run.sh isaac-sim"
}

do_uninstall() {
  if image_present; then
    fm_log "removing $FM_ISAAC_IMAGE"
    docker image rm "$FM_ISAAC_IMAGE"
    fm_ok "image removed"
  else
    fm_skip "$FM_ISAAC_IMAGE not present"
  fi
  # The cache is re-downloadable but expensive to rebuild, and it is the user's
  # data rather than ours.
  fm_warn "$FM_ISAAC_CACHE_DIR left in place — remove it deliberately if you want the disk back"
}

fm_dispatch "$@"
