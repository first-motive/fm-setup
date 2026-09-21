#!/usr/bin/env bash
#
# ffmpeg — the shared libraries torchcodec decodes video through.
#
# LeRobot reads a dataset's video with torchcodec, and torchcodec dlopens the
# whole FFmpeg library set: libavutil, libavcodec, libavformat, libavdevice,
# libavfilter, libswscale, libswresample. One of them missing is not an error
# anywhere — LeRobot logs a traceback and falls back to pyav, which decoded the
# 32-episode checkers-bag-v1 dataset roughly ten times slower. fm-ws-01 ran that
# way for weeks because other packages had pulled in six of the seven.
#
# The `ffmpeg` package rather than the libraries by name: it depends on all
# seven, and their names carry a soname that changes with every Ubuntu release
# (libavdevice60, libavdevice62). Before fm-policy and anvil-embodied-ai, which
# are the two venvs that load it.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$_here/../../lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$_here/../manifest.sh"

fm_require_linux

do_check() {
  local p
  for p in "${FM_FFMPEG_APT[@]}"; do
    if fm_has_pkg "$p"; then fm_ok "$p"; else fm_warn "$p missing — LeRobot decodes video through pyav, about ten times slower"; fi
  done
  return 0
}

do_install() {
  fm_apt_install ffmpeg "${FM_FFMPEG_APT[@]}"
}

do_uninstall() {
  fm_apt_uninstall ffmpeg || fm_warn "ffmpeg left in place"
}

fm_dispatch "$@"
