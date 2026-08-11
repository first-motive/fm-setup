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
  local p missing=()
  for p in "${FM_APT_BASE[@]}"; do
    fm_has_pkg "$p" || missing+=("$p")
  done

  if [ "${#missing[@]}" -eq 0 ]; then
    fm_ok "base deps present"
    return 0
  fi

  fm_log "apt install ${missing[*]}"
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
  fm_ok "base deps installed"
}

do_uninstall() {
  fm_warn "base deps (curl, git, gnupg) underpin the rest of the system — left in place"
  return 0
}

fm_dispatch "$@"
