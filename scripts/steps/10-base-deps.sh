#!/usr/bin/env bash
#
# base-deps — the apt packages every later step assumes are present.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$_here/../../lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$_here/../manifest.sh"

fm_require_linux

do_check() {
  local p
  for p in "${FM_APT_BASE[@]}"; do
    if fm_has_pkg "$p"; then fm_ok "$p"; else fm_warn "$p missing"; fi
  done
  return 0
}

do_install() {
  fm_apt_install base-deps "${FM_APT_BASE[@]}"
}

do_uninstall() {
  fm_warn "base deps (curl, git, gnupg) underpin the rest of the system — left in place"
  return 0
}

fm_dispatch "$@"
