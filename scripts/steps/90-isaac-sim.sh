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
  # First, because the driver and the GPU are worth reporting even on a host
  # whose docker is not up yet.
  isaac_report

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

  return 0
}

# version_ge HAVE WANT — 0 when HAVE is WANT or later.
version_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

# What Isaac Sim 4.5 needs from the host: a driver at or above the lowest it
# lists, a GPU, and that GPU inside a container. Reported, never installed —
# the driver is 20-nvidia's and the toolkit 35-nvidia-container's. Each is its
# own line, so the one that fails is the one named, and nothing is pulled.
isaac_report() {
  local query driver name mem problems=0
  if ! fm_has_cmd nvidia-smi; then
    fm_warn "no nvidia-smi — no NVIDIA driver here; the nvidia step installs it"
    problems=$((problems + 1))
  else
    query="$(nvidia-smi --query-gpu=driver_version,name,memory.total --format=csv,noheader,nounits 2>/dev/null | head -n1 || true)"
    if [ -z "$query" ]; then
      fm_warn "nvidia-smi finds no GPU — the driver is not loaded, or there is no card"
      problems=$((problems + 1))
    else
      driver="$(printf '%s' "$query" | awk -F', *' '{print $1}')"
      name="$(printf '%s' "$query" | awk -F', *' '{print $2}')"
      mem="$(printf '%s' "$query" | awk -F', *' '{print $3}')"
      fm_ok "GPU present: $name (${mem} MiB)"
      if version_ge "$driver" "$FM_ISAAC_DRIVER_MIN"; then
        fm_ok "driver $driver (Isaac Sim 4.5 wants $FM_ISAAC_DRIVER_MIN or later)"
      else
        fm_warn "driver $driver is older than $FM_ISAAC_DRIVER_MIN, the lowest Isaac Sim 4.5 lists"
        problems=$((problems + 1))
      fi
    fi
  fi

  if ! fm_has_docker; then
    fm_warn "docker not reachable — cannot test the GPU inside a container"
    problems=$((problems + 1))
  elif ! docker image inspect "$FM_CUDA_SMOKE_IMAGE" >/dev/null 2>&1; then
    fm_warn "$FM_CUDA_SMOKE_IMAGE not pulled — the container GPU test needs it: docker pull $FM_CUDA_SMOKE_IMAGE"
    problems=$((problems + 1))
  elif fm_docker_gpu_ok --pull=never; then
    fm_ok "the GPU is visible inside containers (nvidia-container-toolkit works)"
  else
    fm_warn "the GPU is not visible inside containers — check the nvidia-container step"
    problems=$((problems + 1))
  fi

  if [ "$problems" -eq 0 ]; then
    fm_ok "this host can run Isaac Sim 4.5"
  else
    fm_warn "this host cannot run Isaac Sim 4.5 yet ($problems problem(s) above)"
  fi
}

# The GPU has to be visible from inside a container, not merely present on the
# host (fm_docker_gpu_ok). This fails loudly rather than leaving Isaac Sim to
# fail obscurely much later.
# The smoke container runs as nobody (fm_docker_gpu_ok passes --user): nvidia-smi
# needs no root, so the install-time test proves the same thing it did as root.
gpu_smoke_test() {
  fm_log "GPU smoke test: nvidia-smi inside a container"
  if fm_docker_gpu_ok; then
    fm_ok "the GPU is visible inside containers"
    return 0
  fi
  fm_err "the GPU is not visible inside containers"
  fm_info "check the nvidia-container step, then: docker run --rm --gpus all $FM_CUDA_SMOKE_IMAGE nvidia-smi"
  return 1
}

do_install() {
  if ! fm_has_docker; then
    # Docker installed and running, but this user declined the docker group —
    # the documented safe answer in the docker step. That is a skip, not a
    # failure: the message used to claim docker was missing and abort the whole
    # run (#32).
    if fm_has_cmd docker && sudo -n docker info >/dev/null 2>&1; then
      fm_skip "docker group declined — isaac-sim skipped; rerun after: sudo usermod -aG docker $(id -un) (then log back in)"
      return 0
    fi
    fm_err "docker is not reachable — run the docker step first"
    return 1
  fi

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
