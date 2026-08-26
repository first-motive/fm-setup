#!/usr/bin/env bash
#
# docker — Docker Engine from Docker's own apt repo.
#
# Not `docker.io`, not snap. The compose files in fm-docker use
# `deploy.resources.reservations.devices`, which is Compose v2 syntax that the
# distro's v1 `docker-compose` cannot parse, and snap's confinement breaks the
# bind mounts the stack needs.
#
# Source: https://docs.docker.com/engine/install/ubuntu/

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$_here/../../lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$_here/../manifest.sh"

fm_require_linux

# The account whose docker-group membership this step reports on and manages.
#
# $USER is set by a login shell and by systemd for a unit with User=, and by
# neither a bare `docker run`, a cron entry, nor a plain `sh -c`. Under `set -u`
# a missing $USER does not degrade the report — it aborts the step, and this
# step is one of fourteen the appliance timer runs unattended. `id -un` answers
# the same question without depending on the caller's environment.
USER="${USER:-$(id -un)}"

KEYRING=/etc/apt/keyrings/docker.asc
SOURCES=/etc/apt/sources.list.d/docker.sources

do_check() {
  if [ -f "$SOURCES" ]; then fm_ok "docker apt repo present"; else fm_warn "docker apt repo missing"; fi
  local p
  for p in "${FM_DOCKER_APT[@]}"; do
    if fm_has_pkg "$p"; then fm_ok "$p"; else fm_warn "$p missing"; fi
  done
  if fm_has_docker; then
    fm_ok "docker daemon reachable ($(docker --version))"
  else
    fm_warn "docker daemon not reachable as $USER"
  fi
  if id -nG "$USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
    fm_ok "$USER is in the docker group"
  else
    fm_warn "$USER is not in the docker group"
  fi
  return 0
}

add_repo() {
  local codename
  codename="$(fm_os_codename)"
  fm_log "adding Docker's apt repo ($codename)"

  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$KEYRING"
  sudo chmod a+r "$KEYRING"

  sudo tee "$SOURCES" >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $codename
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: $KEYRING
EOF
  sudo apt-get update
}

do_install() {
  # The distro's own docker packages conflict with Docker's. Remove them first,
  # exactly as Docker's install guide does.
  local p
  for p in "${FM_DOCKER_CONFLICTS[@]}"; do
    fm_has_pkg "$p" && sudo apt-get remove -y "$p"
  done

  [ -f "$SOURCES" ] || add_repo

  local missing=()
  for p in "${FM_DOCKER_APT[@]}"; do
    fm_has_pkg "$p" || missing+=("$p")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    fm_log "apt install ${missing[*]}"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
  else
    fm_ok "docker packages present"
  fi

  if id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
    fm_ok "$USER already in the docker group"
    return 0
  fi

  # Membership of the docker group is root: anyone in it can start a container
  # that mounts the host filesystem. That is a deliberate grant, so it is asked
  # for rather than assumed, and an unattended run declines and says so.
  fm_warn "the docker group is equivalent to root — a member can mount the host filesystem into a container"
  fm_info "declining is fine for the rig; on the workstation isaac-sim needs it and is skipped without it"
  if fm_confirm "Add $USER to the docker group?"; then
    sudo usermod -aG docker "$USER"
    fm_warn "$USER added to the docker group — log out and back in for it to take effect"
  else
    fm_skip "docker group membership declined — run docker with sudo, or add the user later with: sudo usermod -aG docker $USER"
  fi
}

do_uninstall() {
  local p installed=()
  for p in "${FM_DOCKER_APT[@]}"; do
    fm_has_pkg "$p" && installed+=("$p")
  done
  if [ "${#installed[@]}" -gt 0 ]; then
    fm_log "apt remove ${installed[*]}"
    sudo apt-get remove -y "${installed[@]}"
  fi
  sudo rm -f "$SOURCES" "$KEYRING"
  # Images, volumes, and networks live in /var/lib/docker and are left alone:
  # removing them would destroy pulled models and dataset volumes.
  fm_warn "/var/lib/docker left in place — remove it deliberately if you mean to drop every image and volume"
}

fm_dispatch "$@"
