#!/usr/bin/env bash
#
# ros2 — the ROS 2 distro this role runs natively.
#
# The distro follows the role, not the machine: the 26.04 workstation runs
# Lyrical, the 22.04 Jetson runs Humble. fm-setup installs the distro; the
# workspace on top of it belongs to fm_ros2.
#
# The apt source comes from the `ros2-apt-source` package rather than a
# hand-written keyring entry. ROS rotated its signing key in 2025 and the
# package carries the current one, so a machine provisioned a year from now does
# not fail on an expired key baked into this script.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$_here/../../lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$_here/../manifest.sh"

fm_require_linux

# Echo this role's ROS distro. FM_ROLE is exported by the front door; a step run
# standalone falls back to detection.
ros_distro() {
  local role="${FM_ROLE:-$(fm_detect_role)}"
  case "$role" in
    workstation) printf '%s\n' "$FM_ROS_DISTRO_WORKSTATION" ;;
    jetson)      printf '%s\n' "$FM_ROS_DISTRO_JETSON" ;;
    *) fm_err "unknown role: $role"; return 1 ;;
  esac
}

# Echo this role's ROS package list, one per line.
ros_packages() {
  local role="${FM_ROLE:-$(fm_detect_role)}" p
  case "$role" in
    workstation) for p in "${FM_ROS_APT_WORKSTATION[@]}"; do printf '%s\n' "$p"; done ;;
    jetson)      for p in "${FM_ROS_APT_JETSON[@]}";      do printf '%s\n' "$p"; done ;;
    *) fm_err "unknown role: $role"; return 1 ;;
  esac
}

do_check() {
  local distro p
  distro="$(ros_distro)"
  if [ -d "/opt/ros/$distro" ]; then fm_ok "/opt/ros/$distro present"; else fm_warn "/opt/ros/$distro missing"; fi
  while IFS= read -r p; do
    if fm_has_pkg "$p"; then fm_ok "$p"; else fm_warn "$p missing"; fi
  done < <(ros_packages)
  if [ -f /etc/ros/rosdep/sources.list.d/20-default.list ]; then
    fm_ok "rosdep initialised"
  else
    fm_warn "rosdep not initialised"
  fi
  return 0
}

add_repo() {
  local codename deb
  codename="$(fm_os_codename)"
  fm_log "adding the ROS 2 apt source ($FM_ROS_APT_SOURCE_VERSION, $codename)"

  deb="$(mktemp --suffix=.deb)"

  # Cleanup is explicit rather than a `trap … RETURN`. A RETURN trap is not
  # scoped to the function that sets it: it stays armed and fires again when the
  # *caller* returns, where $deb no longer exists, and under `set -u` that
  # aborts the run after the step has already succeeded. Container rehearsal on
  # jammy found it; the symptom was provisioning stopping dead after ROS with
  # every later step skipped.
  local rc=0
  _add_repo_inner "$codename" "$deb" || rc=$?
  rm -f "$deb"
  [ "$rc" -eq 0 ] || return "$rc"

  sudo apt-get update
}

# Fetch, verify, and install the apt source package. Split out so add_repo owns
# the temp file's whole life: one place creates it, one place removes it.
_add_repo_inner() {
  local codename="$1" deb="$2" entry want=""

  curl -fsSL -o "$deb" \
    "https://github.com/ros-infrastructure/ros-apt-source/releases/download/${FM_ROS_APT_SOURCE_VERSION}/ros2-apt-source_${FM_ROS_APT_SOURCE_VERSION}.${codename}_all.deb"

  # apt verifies the package's own signature on install, and the version is
  # pinned rather than resolved to "latest". The manifest also carries a sha256
  # per codename, so a tampered download is rejected before it reaches dpkg.
  for entry in ${FM_ROS_APT_SOURCE_SHA256_MAP[@]+"${FM_ROS_APT_SOURCE_SHA256_MAP[@]}"}; do
    if [ "${entry%%|*}" = "$codename" ]; then
      want="${entry#*|}"
      break
    fi
  done
  if [ -n "$want" ]; then
    fm_verify_checksum "$deb" "$want" || return 1
    fm_ok "apt source checksum verified"
  else
    # Not fatal: a codename nobody has pinned yet still installs, and apt still
    # checks the package signature. Silence would be the problem.
    fm_warn "no apt source checksum pinned for '$codename' — add one to the manifest"
  fi

  sudo apt-get install -y "$deb"
}

do_install() {
  local distro codename p missing=()
  distro="$(ros_distro)"
  codename="$(fm_os_codename)"

  fm_log "ROS 2 $distro on $codename"
  sudo add-apt-repository -y universe

  [ -f /etc/apt/sources.list.d/ros2-apt-source.list ] \
    || [ -f /etc/apt/sources.list.d/ros2.list ] \
    || add_repo

  while IFS= read -r p; do
    fm_has_pkg "$p" || missing+=("$p")
  done < <(ros_packages)

  if [ "${#missing[@]}" -gt 0 ]; then
    fm_log "apt install ${missing[*]}"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
  else
    fm_ok "ROS packages present"
  fi

  if [ ! -f /etc/ros/rosdep/sources.list.d/20-default.list ]; then
    fm_log "rosdep init"
    sudo rosdep init
  fi

  # Not a bare `rosdep update`. It fetches its sources unauthenticated from
  # raw.githubusercontent.com and exits non-zero if any one of them is throttled,
  # including a ROS 1 Fuerte source nothing here consumes. Under `set -e` that
  # aborts this step — and an abort here is not a failed build, it is a rig left
  # provisioned up to ROS and no further, on a timer nobody is watching.
  #
  # The helper is rendered from the First Motive render plane, so the CI
  # workflows and this step run the same code.
  fm_log "rosdep update"
  "$_here/../../.fm/rosdep-update.sh" "$(ros_distro)"

  # A login shell that does not source the distro leaves `ros2` missing and
  # every ROS command failing for a reason nobody guesses quickly.
  if [ "${FM_NO_MODIFY_PATH:-0}" = "1" ]; then
    fm_info "FM_NO_MODIFY_PATH set — not touching ~/.bashrc"
  else
    fm_ensure_line "$HOME/.bashrc" "source /opt/ros/$distro/setup.bash"
    fm_ok "$HOME/.bashrc sources /opt/ros/$distro"
  fi

  fm_ok "ROS 2 $distro ready"
}

do_uninstall() {
  local distro
  distro="$(ros_distro)"
  fm_strip_line "$HOME/.bashrc" "source /opt/ros/$distro/setup.bash"
  fm_warn "ROS packages, the apt source, and rosdep state are system-level — left in place"
  fm_info "remove them deliberately with: sudo apt-get remove 'ros-$distro-*'"
}

fm_dispatch "$@"
