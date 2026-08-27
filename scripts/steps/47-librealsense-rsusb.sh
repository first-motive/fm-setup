#!/usr/bin/env bash
#
# librealsense-rsusb — a source-built librealsense the D4xx IMU actually works
# under, diverted over the ROS-vendored binary.
#
# The apt/ROS librealsense on arm64 reaches the camera's motion module through
# the kernel HID layer, and the tegra kernel does not behave the way that
# binary expects. On the recorder rig the failure is total and silent: the
# driver logs "No HID info provided, IMU is disabled" and streams video without
# IMU; older builds that did bind the module segfaulted seconds into streaming
# (fm-recorder-01, 2026-08-13 and 2026-08-26). Intel's own deployment path for
# Jetson is a source build with FORCE_RSUSB_BACKEND=ON, which handles the
# motion module in userspace over libusb and bypasses the kernel HID layer
# entirely.
#
# Building the library is not enough. The ROS wrapper resolves librealsense2 at
# runtime through ament's LD_LIBRARY_PATH, which outranks the RUNPATH a rebuilt
# node carries — the vendored binary wins no matter how the consumer is linked
# (proven on the rig; -Wl,--disable-new-dtags did not take either). So the
# vendored file is replaced through dpkg-divert: official, survives apt
# reinstalls of the same version, and every consumer — the apt wrapper, a
# workspace build, rs-enumerate-devices — loads the RSUSB build with no
# environment cooperation required.
#
# The build is pinned to the vendored package's own upstream version, so the
# ABI under the diversion is identical to the ABI apt shipped. When apt moves
# to a new librealsense version the diverted filename changes with it, the old
# diversion goes inert, and this step reports drift on check and rebuilds on
# install — convergence, not a one-shot.
#
# First install compiles for ~40 minutes on an Orin Nano. Re-runs are free: the
# clone, the build tree, and the installed prefix all persist and are keyed by
# version.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$_here/../.." && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$FM_ROOT/lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$FM_ROOT/scripts/manifest.sh"

fm_require_linux

# Jetson-only step (registered in JETSON_STEPS alone): the x86 workstation's
# apt librealsense binds the IMU fine, and diverting a healthy library would
# be pure risk. The distro is therefore the Jetson's, not a role lookup.
ROS_DISTRO_PKG="ros-${FM_ROS_DISTRO_JETSON}-librealsense2"
VENDOR_DIR="/opt/ros/${FM_ROS_DISTRO_JETSON}/lib/aarch64-linux-gnu"
PREFIX=/usr/local
SRC_DIR="$HOME/.first-motive/librealsense"

BUILD_DEPS=(build-essential cmake git libusb-1.0-0-dev libssl-dev libudev-dev pkg-config)

# The upstream tag matching the vendored package: "2.58.3-1jammy…" → "v2.58.3".
# Empty when the ROS package is not installed, which is the step's skip signal —
# a rig with no RealSense wrapper has nothing to divert and nothing to fix.
vendored_version() {
  dpkg-query -W -f '${Version}' "$ROS_DISTRO_PKG" 2>/dev/null | cut -d- -f1
}

vendor_lib()  { printf '%s\n' "$VENDOR_DIR/librealsense2.so.$1"; }
built_lib()   { printf '%s\n' "$PREFIX/lib/librealsense2.so.$1"; }

diversion_active() {
  dpkg-divert --list "$(vendor_lib "$1")" 2>/dev/null | grep -q .
}

do_check() {
  if [ "$(fm_detect_arch)" != "aarch64" ]; then
    fm_skip "arm64 only — the x86 apt librealsense binds the IMU correctly"
    return 0
  fi
  local ver; ver="$(vendored_version)"
  if [ -z "$ver" ]; then
    fm_skip "$ROS_DISTRO_PKG not installed — nothing to divert"
    return 0
  fi

  if [ -f "$(built_lib "$ver")" ]; then
    fm_ok "RSUSB build present: $(built_lib "$ver")"
  else
    fm_warn "no RSUSB build for vendored $ver — IMU dead until built"
  fi

  if diversion_active "$ver" && [ -L "$(vendor_lib "$ver")" ]; then
    fm_ok "vendored lib diverted to the RSUSB build"
  else
    fm_warn "vendored $ver not diverted — consumers load the kernel-HID binary"
  fi
  return 0
}

ensure_build_deps() {
  local missing=() p
  for p in "${BUILD_DEPS[@]}"; do fm_has_pkg "$p" || missing+=("$p"); done
  if [ "${#missing[@]}" -gt 0 ]; then
    fm_log "installing build deps: ${missing[*]}"
    sudo apt-get install -y "${missing[@]}"
  fi
}

build_library() {
  local ver="$1" tag="v$1"
  ensure_build_deps

  if [ ! -d "$SRC_DIR/.git" ] || ! git -C "$SRC_DIR" rev-parse -q --verify "refs/tags/$tag" >/dev/null 2>&1; then
    rm -rf "$SRC_DIR"
    fm_log "cloning librealsense $tag"
    git clone --depth 1 --branch "$tag" https://github.com/IntelRealSense/librealsense "$SRC_DIR"
  fi

  fm_log "building librealsense $tag with the RSUSB backend (long on first run)"
  cmake -S "$SRC_DIR" -B "$SRC_DIR/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DFORCE_RSUSB_BACKEND=ON \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_GRAPHICAL_EXAMPLES=OFF \
    -DBUILD_TOOLS=ON \
    -DBUILD_WITH_CUDA=OFF \
    -DCMAKE_INSTALL_PREFIX="$PREFIX"
  cmake --build "$SRC_DIR/build" -j "$(( $(nproc) - 1 ))"
  sudo cmake --install "$SRC_DIR/build"
  sudo ldconfig
}

do_install() {
  if [ "$(fm_detect_arch)" != "aarch64" ]; then
    fm_skip "arm64 only — the x86 apt librealsense binds the IMU correctly"
    return 0
  fi
  local ver; ver="$(vendored_version)"
  if [ -z "$ver" ]; then
    fm_skip "$ROS_DISTRO_PKG not installed — nothing to divert"
    return 0
  fi

  if [ -f "$(built_lib "$ver")" ]; then
    fm_ok "RSUSB $ver already built"
  else
    build_library "$ver"
    [ -f "$(built_lib "$ver")" ] || { fm_err "build finished but $(built_lib "$ver") missing"; return 1; }
  fi

  local vendor; vendor="$(vendor_lib "$ver")"
  if ! diversion_active "$ver"; then
    fm_log "diverting $vendor"
    sudo dpkg-divert --add --rename --divert "$vendor.distrib" "$vendor"
  fi
  if [ "$(readlink -f "$vendor" 2>/dev/null)" != "$(readlink -f "$(built_lib "$ver")")" ]; then
    sudo ln -sfn "$(built_lib "$ver")" "$vendor"
  fi
  fm_ok "vendored librealsense $ver diverted to the RSUSB build"

  # Services that already loaded the vendored binary keep it until they
  # restart; the recorder's role installer restarts fm-recorder anyway.
}

do_uninstall() {
  local ver; ver="$(vendored_version)"
  if [ -n "$ver" ] && diversion_active "$ver"; then
    sudo rm -f "$(vendor_lib "$ver")"
    sudo dpkg-divert --remove --rename "$(vendor_lib "$ver")"
    fm_ok "diversion removed — vendored $ver restored"
  else
    fm_skip "no diversion to remove"
  fi

  if [ -f "$SRC_DIR/build/install_manifest.txt" ]; then
    sudo xargs -r rm -f < "$SRC_DIR/build/install_manifest.txt"
    sudo ldconfig
    fm_ok "RSUSB build removed from $PREFIX"
  else
    fm_skip "no install manifest — $PREFIX files left in place"
  fi
}

fm_dispatch "$@"
