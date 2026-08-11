#!/usr/bin/env bash
#
# isaac-sim — launch the Isaac Sim container.
#
#   ./run.sh isaac-sim                    headless, streamed to an Omniverse client
#   ./run.sh isaac-sim -- ./runheadless.sh --/app/quitAfter=100
#
# Headless by default: this workstation is usually reached over the tailnet, and
# a GUI Isaac Sim needs an X server on the machine itself. Connect to the stream
# from Omniverse Streaming Client on your own machine.
#
# The host cache mounts are what make a second launch fast — without them every
# start rebuilds the shader cache from cold.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$_here/../.." && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$FM_ROOT/lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$FM_ROOT/scripts/manifest.sh"

usage() {
  cat <<'EOF'
isaac-sim — launch the Isaac Sim container

Usage: ./run.sh isaac-sim [-- <command> [args…]]
       ./run.sh isaac-sim --shell
       ./run.sh isaac-sim --help

  (no args)    run headless, streaming to an Omniverse client
  --shell      drop into a shell inside the container
  -- <cmd>     run a command inside the container instead

Pull the image first with: ./install.sh --only isaac-sim
EOF
}

main() {
  local shell=0
  local cmd=()

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help) usage; return 0 ;;
      --shell)   shell=1; shift ;;
      --)        shift; cmd=("$@"); break ;;
      *) fm_err "unknown option: $1"; usage; return 1 ;;
    esac
  done

  fm_require_linux
  fm_has_docker || { fm_err "docker is not reachable"; return 1; }

  if ! docker image inspect "$FM_ISAAC_IMAGE" >/dev/null 2>&1; then
    fm_err "$FM_ISAAC_IMAGE is not pulled — run: ./install.sh --only isaac-sim"
    return 1
  fi

  # The mounts map each of Isaac Sim's in-container cache and log paths onto a
  # host directory the isaac-sim step created.
  local mounts=() entry sub target
  for entry in "${FM_ISAAC_CACHE_MAP[@]}"; do
    IFS='|' read -r sub target <<<"$entry"
    mounts+=(-v "$FM_ISAAC_CACHE_DIR/$sub:$target:rw")
  done

  if [ "$shell" = "1" ]; then
    cmd=(/bin/bash)
  elif [ "${#cmd[@]}" -eq 0 ]; then
    cmd=(./runheadless.sh)
  fi

  fm_log "launching $FM_ISAAC_IMAGE"
  # --network host so the streaming ports reach the tailnet without a published
  # port list; -e ACCEPT_EULA=Y because the image refuses to start otherwise.
  exec docker run --rm -it \
    --gpus all \
    --network host \
    -e "ACCEPT_EULA=${FM_ISAAC_ACCEPT_EULA}" \
    -e "PRIVACY_CONSENT=${FM_ISAAC_PRIVACY_CONSENT}" \
    "${mounts[@]}" \
    "$FM_ISAAC_IMAGE" \
    "${cmd[@]}"
}

main "$@"
