#!/usr/bin/env bash
#
# anvil-embodied-ai — Anvil's inference and conversion stack, in the workspace.
#
# A workstation is the host an Anvil rig names as its inference server, and the
# host that turns the rig's recordings into datasets. Both jobs are Anvil's own
# code: `fm policy serve --target anvil` hands a trained run to their
# `lerobot_control` node, and `fm policy dataset import` runs their `mcap-valid`
# → `mcap-convert` → `dataset-valid` over a recording. fm-policy delegates to
# this checkout and refuses by name when it is absent, so putting it here is
# what makes those two verbs reachable at all.
#
# It runs after docker and the container toolkit because it builds an image, and
# a build is the one thing in this step that cannot be done without them.
#
# From First Motive's fork rather than upstream: the fork is where the LeRobot
# version is pinned to the one fm-policy trains with. A checkpoint trained under
# one release and served under another is the failure that pin exists to
# prevent, and this step is what puts the matching pin on the serving host.
#
# Cloned, never updated, for the reason 17-fm-policy.sh gives: `git pull` under
# a run that is already going moves the code beneath it. Bringing it forward is
# a person's job.
#
# What this step does not decide is which robot this workstation talks to. The
# CycloneDDS profile it writes names this host's interface and the rig's
# address, and both are facts about one installation rather than about the role
# — so both are read from the environment, with the values fm-ws-01 uses as the
# defaults, and a host that differs says so when it runs the step.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$_here/../.." && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$FM_ROOT/lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$FM_ROOT/scripts/manifest.sh"

fm_require_linux

ANVIL_DIR="$(fm_machine_workspace)/$FM_ANVIL_CHECKOUT_NAME"
ANVIL_URL="https://github.com/$FM_ANVIL_REPO.git"

# The two facts about this installation rather than about the role. Overridable
# on the command line, because the second workstation to run this step will not
# have the first one's interface.
ANVIL_IFACE="${FM_ANVIL_IFACE:-$FM_ANVIL_IFACE_DEFAULT}"
ANVIL_PEER="${FM_ANVIL_PEER_IP:-$FM_ANVIL_PEER_IP_DEFAULT}"

# Both values are written into an XML document below, so both are held to what
# they are allowed to be first. Not because the operator running this under sudo
# is untrusted — they already are root — but because the failure otherwise is
# the worst kind this step can produce: a profile that parses as something, and
# a rig that discovers nothing, with no line anywhere saying why. A typo is
# refused here instead, by name.
check_iface() {
  case "$ANVIL_IFACE" in
    "" ) fm_err "FM_ANVIL_IFACE is empty — name the interface this host reaches the rig on"; return 1 ;;
    *[!A-Za-z0-9_.-]* )
      fm_err "FM_ANVIL_IFACE '$ANVIL_IFACE' is not an interface name"
      fm_info "this host's interfaces: $(ip -brief link 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
      return 1 ;;
  esac
  # Named, but not present: still refused, because a profile bound to an
  # interface this machine does not have is one that never discovers anything.
  if ! ip link show "$ANVIL_IFACE" >/dev/null 2>&1; then
    fm_err "$ANVIL_IFACE is not an interface on this host"
    fm_info "this host's interfaces: $(ip -brief link 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
    return 1
  fi
  return 0
}

check_peer() {
  local octet
  case "$ANVIL_PEER" in
    *[!0-9.]* | "" )
      fm_err "FM_ANVIL_PEER_IP '$ANVIL_PEER' is not an IPv4 address — it is the rig's address on $ANVIL_IFACE"
      return 1 ;;
  esac
  # Four octets, each in range. `case` alone accepts "1.2.3.4.5" and "999.0.0.1".
  [ "$(printf '%s' "$ANVIL_PEER" | tr -cd . | wc -c)" -eq 3 ] || {
    fm_err "FM_ANVIL_PEER_IP '$ANVIL_PEER' is not an IPv4 address"
    return 1
  }
  for octet in ${ANVIL_PEER//./ }; do
    if [ -z "$octet" ] || [ "$octet" -gt 255 ] 2>/dev/null; then
      fm_err "FM_ANVIL_PEER_IP '$ANVIL_PEER' is not an IPv4 address"
      return 1
    fi
  done
  return 0
}

# Where the generated profile goes. Beside their own, not over it: theirs is an
# example carrying an example address, and overwriting it would leave nothing
# saying what the shipped values were.
PROFILE_NAME="fm_two_pc_gpu.xml"
PROFILE_PATH="$ANVIL_DIR/configs/cyclonedds/$PROFILE_NAME"

do_check() {
  if [ ! -d "$ANVIL_DIR/.git" ]; then
    fm_warn "$ANVIL_DIR missing — 'fm policy dataset import' and 'serve --target anvil' will refuse"
    return 0
  fi
  fm_ok "$ANVIL_DIR ($(git -C "$ANVIL_DIR" rev-parse --short HEAD 2>/dev/null || echo 'no commit'))"

  # A checkout is not a working stack. Each of these is one of the three things
  # fm-policy reaches for, reported on its own so a partial install says which
  # half is missing rather than failing later inside a verb.
  if [ -f "$ANVIL_DIR/.env" ]; then
    fm_ok "$ANVIL_DIR/.env written"
  else
    fm_warn "$ANVIL_DIR/.env missing — 'serve --target anvil' refuses without it"
  fi
  if [ -d "$ANVIL_DIR/.venv" ]; then
    fm_ok "$ANVIL_DIR/.venv resolved"
  else
    fm_warn "$ANVIL_DIR/.venv missing — the mcap tools 'dataset import' runs are not installed"
  fi
  if fm_has_docker && docker image inspect "$FM_ANVIL_IMAGE" >/dev/null 2>&1; then
    fm_ok "$FM_ANVIL_IMAGE built"
  else
    fm_warn "$FM_ANVIL_IMAGE not built — the inference node has no image to run"
  fi
  return 0
}

# uv lands in ~/.local/bin, which reaches PATH only after a new login shell.
# Neither has happened during provisioning, so look there directly — 15-fm-cli
# and 17-fm-policy resolve it the same way.
uv_bin() {  # home
  local home="$1"
  if fm_has_cmd uv; then command -v uv; return 0; fi
  [ -x "$home/.local/bin/uv" ] && printf '%s\n' "$home/.local/bin/uv" && return 0
  return 1
}

# Who the checkout belongs to: the workspace's owner. Not root — this step runs
# under sudo, and a root-owned tree inside a group-writable workspace is one
# nobody can work in afterwards. Mirrors 17-fm-policy.sh.
workspace_owner() {
  local workspace
  workspace="$(fm_machine_workspace)"
  if [ -d "$workspace" ]; then
    stat -c '%U' "$workspace" 2>/dev/null && return 0
  fi
  printf '%s\n' "${SUDO_USER:-${USER:-$(id -un)}}"
}

as_workspace_owner() {
  local owner
  owner="$(workspace_owner)"
  if [ "$owner" = "$(id -un)" ]; then
    "$@"
  else
    sudo -u "$owner" "$@"
  fi
}

# The DDS profile this host talks to the rig over. Generated rather than copied:
# their `two_pc_gpu.xml` names `eno1` and an example peer, and a profile with
# the wrong interface in it discovers nothing while looking correct.
write_profile() {
  fm_log "writing $PROFILE_PATH (interface $ANVIL_IFACE, peer $ANVIL_PEER)"
  as_workspace_owner tee "$PROFILE_PATH" >/dev/null <<PROFILE
<?xml version="1.0" encoding="UTF-8" ?>
<!-- Written by fm-setup's anvil-embodied-ai step. Their two_pc_gpu.xml is the
     shipped example; this one carries this workstation's own interface and the
     rig it discovers. Re-run the step with FM_ANVIL_IFACE / FM_ANVIL_PEER_IP
     to change either. -->
<CycloneDDS xmlns="https://cdds.io/config">
    <Domain id="any">
        <General>
            <Interfaces>
                <NetworkInterface name="$ANVIL_IFACE"/>
            </Interfaces>
            <AllowMulticast>true</AllowMulticast>
            <MaxMessageSize>65535B</MaxMessageSize>
            <FragmentSize>4000B</FragmentSize>
        </General>
        <Discovery>
            <Peers>
                <Peer address="$ANVIL_PEER"/>
            </Peers>
        </Discovery>
        <Internal>
            <SocketReceiveBufferSize min="128MB"/>
            <Watermarks>
                <WhcHigh>8MB</WhcHigh>
            </Watermarks>
        </Internal>
    </Domain>
</CycloneDDS>
PROFILE
  fm_ok "$PROFILE_NAME written"
}

# The `.env` their compose project reads. Seeded from their own example so every
# key and comment they ship survives, with the four this host decides set on
# top.
#
# Written once and then left alone. `fm policy serve --target anvil` edits
# MODEL_PATH, CONFIG_FILE, LEROBOT_EXTRAS and HF_CACHE in this file on every
# run, so a step that rewrote it would undo whichever run is being served.
write_env() {
  local env_path="$ANVIL_DIR/.env"
  if [ -f "$env_path" ]; then
    fm_ok "$env_path already written"
    fm_info "it is edited per run by 'fm policy serve --target anvil'; left as it is"
    return 0
  fi
  [ -f "$ANVIL_DIR/.env.example" ] || {
    fm_warn "$ANVIL_DIR/.env.example missing — cannot seed .env"
    return 0
  }

  fm_log "writing $env_path"
  as_workspace_owner cp "$ANVIL_DIR/.env.example" "$env_path"
  # The ROS domain and the RMW must match the rig's own .env.config, and the
  # profile is the one written above rather than their example. The container
  # sees the checkout at /workspace, which is what makes this path the right one
  # inside it.
  as_workspace_owner sed -i \
    -e "s|^ROS_DOMAIN_ID=.*|ROS_DOMAIN_ID=$FM_ANVIL_ROS_DOMAIN_ID|" \
    -e "s|^RMW_IMPLEMENTATION=.*|RMW_IMPLEMENTATION=rmw_cyclonedds_cpp|" \
    -e "s|^CYCLONEDDS_URI=.*|CYCLONEDDS_URI=file:///workspace/configs/cyclonedds/$PROFILE_NAME|" \
    -e "s|^LEROBOT_EXTRAS=.*|LEROBOT_EXTRAS=$FM_ANVIL_LEROBOT_EXTRAS|" \
    "$env_path"
  fm_ok "$env_path written (domain $FM_ANVIL_ROS_DOMAIN_ID, $PROFILE_NAME)"
}

# The Python side: the mcap tools `fm policy dataset import` runs. The extras are
# the policies this host serves — LeRobot gates SmolVLA and pi0.5 inside the
# model's own __init__, so a missing extra fails after a checkpoint has already
# been loaded.
ensure_installed() {  # owner  home
  local owner="$1" home="$2" uv
  if ! uv="$(uv_bin "$home")"; then
    fm_warn "uv is not installed for $owner — cannot resolve $ANVIL_DIR/.venv"
    fm_info "the fm-cli step installs it; re-run: ./install.sh --workstation --only fm-cli,anvil-embodied-ai"
    return 0
  fi
  fm_log "resolving $ANVIL_DIR/.venv (as $owner) — torch and lerobot, slow once"
  # shellcheck disable=SC2086
  if as_workspace_owner env PATH="$(dirname "$uv"):$PATH" \
      "$uv" sync --project "$ANVIL_DIR" --all-packages $FM_ANVIL_UV_EXTRAS >/dev/null 2>&1; then
    fm_ok "$ANVIL_DIR/.venv resolved"
  else
    fm_warn "could not resolve $ANVIL_DIR/.venv — 'fm policy dataset import' will not run yet"
    fm_info "run it directly to see why: $uv sync --project $ANVIL_DIR --all-packages $FM_ANVIL_UV_EXTRAS"
  fi
}

# The inference image. A warning rather than a failure: the conversion half of
# this checkout works without it, and a workstation that cannot reach a registry
# still has the rest of its role.
build_image() {
  if ! fm_has_docker; then
    if fm_has_cmd docker && sudo -n docker info >/dev/null 2>&1; then
      fm_skip "docker group declined — image not built; re-run after: sudo usermod -aG docker $(id -un)"
      return 0
    fi
    fm_warn "docker is not reachable — run the docker step first, then re-run this one"
    return 0
  fi
  if docker image inspect "$FM_ANVIL_IMAGE" >/dev/null 2>&1; then
    fm_ok "$FM_ANVIL_IMAGE already built"
    fm_info "rebuild deliberately with: docker compose -f $ANVIL_DIR/docker-compose.yml build"
    return 0
  fi

  fm_log "building $FM_ANVIL_IMAGE (lerobot $FM_ANVIL_LEROBOT_VERSION, extras $FM_ANVIL_LEROBOT_EXTRAS) — slow once"
  if (cd "$ANVIL_DIR" && docker compose build >/dev/null 2>&1); then
    fm_ok "$FM_ANVIL_IMAGE built"
  else
    fm_warn "could not build $FM_ANVIL_IMAGE — the conversion half of this checkout still works"
    fm_info "run it directly to see why: cd $ANVIL_DIR && docker compose build"
  fi
}

do_install() {
  local owner home
  owner="$(workspace_owner)"
  home="$(getent passwd "$owner" 2>/dev/null | cut -d: -f6)"
  [ -n "$home" ] || home="$HOME"

  if [ -e "$ANVIL_DIR" ] && [ ! -d "$ANVIL_DIR/.git" ]; then
    fm_warn "$ANVIL_DIR exists and is not a checkout — leaving it"
    return 0
  fi

  if [ -d "$ANVIL_DIR/.git" ]; then
    fm_ok "$ANVIL_DIR already cloned"
    fm_info "bring it forward deliberately with: git -C $ANVIL_DIR pull"
  else
    fm_require_cmd git || return 1
    fm_ensure_dir "$(dirname "$ANVIL_DIR")"
    fm_log "cloning $FM_ANVIL_REPO into $ANVIL_DIR (as $owner)"
    if ! as_workspace_owner env GIT_TERMINAL_PROMPT=0 git clone --quiet "$ANVIL_URL" "$ANVIL_DIR"; then
      fm_warn "could not clone $FM_ANVIL_REPO — the rest of this role is unaffected"
      fm_info "authenticate as $owner (gh auth login), then re-run:"
      fm_info "  ./install.sh --workstation --only anvil-embodied-ai"
      return 0
    fi
    fm_ok "$ANVIL_DIR cloned"
  fi

  check_iface || return 1
  check_peer || return 1
  write_profile
  write_env
  ensure_installed "$owner" "$home"
  build_image
}

do_uninstall() {
  # The checkout holds a `.env` naming this host's deployment and an image that
  # costs an hour to rebuild. Neither is reconstructible from the repo alone.
  fm_warn "$ANVIL_DIR is left in place — its .env names this host's DDS deployment"
  fm_info "remove it deliberately with: rm -rf $ANVIL_DIR"
  fm_info "and the image with: docker image rm $FM_ANVIL_IMAGE"
  return 0
}

fm_dispatch "$@"
