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
# Overridable so test-docker-repo.sh can stage other entries for Docker's repo
# in a temp directory rather than in the host's own apt configuration.
APT_SOURCES_DIR="${FM_APT_SOURCES_DIR:-/etc/apt/sources.list.d}"
SOURCES="$APT_SOURCES_DIR/docker.sources"
DISABLED_SUFFIX=.fm-setup-disabled

# foreign_docker_entries — print each apt source file other than ours that
# points at Docker's Ubuntu repo, one per line.
#
# apt refuses to read any source list at all when two entries for the same repo
# name different Signed-By keyrings. An image that ships Docker preinstalled
# (the AWS Deep Learning AMI) carries its own entry with its own keyring, so
# adding ours beside it makes every later `apt-get update` fail. A commented-out
# line is not an entry and does not count.
foreign_docker_entries() {
  local f
  for f in "$APT_SOURCES_DIR"/*.list "$APT_SOURCES_DIR"/*.sources; do
    [ -f "$f" ] || continue
    # A symlink belongs to whatever tool placed it, and renaming it as root is
    # not this step's call to make.
    [ -L "$f" ] && continue
    [ "$f" = "$SOURCES" ] && continue
    if grep -Eq '^[[:space:]]*[^#[:space:]].*download\.docker\.com/linux/ubuntu' "$f"; then
      printf '%s\n' "$f"
    fi
  done
}

# disable_foreign_docker_entries — move every foreign entry aside so ours is the
# only one apt reads.
#
# Renamed rather than deleted, and its keyring left alone, so the image's own
# configuration can be put back by hand. apt skips a file in sources.list.d
# whose name ends in neither .list nor .sources.
disable_foreign_docker_entries() {
  local f
  while IFS= read -r f; do
    # An earlier move's file is the only copy of the image's entry from then;
    # overwriting it would lose that, so this one is left for a person.
    if [ -e "$f$DISABLED_SUFFIX" ] || [ -L "$f$DISABLED_SUFFIX" ]; then
      fm_warn "$f also points at Docker's apt repo, and $f$DISABLED_SUFFIX already exists — leaving both; remove one by hand"
      continue
    fi
    fm_warn "$f also points at Docker's apt repo with its own Signed-By — moving it to $f$DISABLED_SUFFIX"
    sudo mv -n -T -- "$f" "$f$DISABLED_SUFFIX"
  done < <(foreign_docker_entries)
}

do_check() {
  if [ -f "$SOURCES" ]; then fm_ok "docker apt repo present"; else fm_warn "docker apt repo missing"; fi
  local f
  while IFS= read -r f; do
    fm_warn "$f also points at Docker's apt repo — two Signed-By values break apt-get update; install moves it aside"
  done < <(foreign_docker_entries)
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

  # Every run, not only the one that writes ours: once ours exists add_repo is
  # skipped, and a foreign entry that appeared since (an image's own, restored
  # or re-added) would still fail the apt-get update fm_apt_install runs.
  disable_foreign_docker_entries
  [ -f "$SOURCES" ] || add_repo

  fm_apt_install docker "${FM_DOCKER_APT[@]}"

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
  fm_apt_uninstall docker || return 1
  sudo rm -f "$SOURCES" "$KEYRING"
  # Images, volumes, and networks live in /var/lib/docker and are left alone:
  # removing them would destroy pulled models and dataset volumes.
  fm_warn "/var/lib/docker left in place — remove it deliberately if you mean to drop every image and volume"
  fm_warn "any $APT_SOURCES_DIR/*$DISABLED_SUFFIX left in place — rename one back to restore the image's own Docker repo entry"
}

fm_dispatch "$@"
