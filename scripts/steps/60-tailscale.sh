#!/usr/bin/env bash
#
# tailscale — the network every machine is reached on.
#
# Brought up with --ssh, so Tailscale SSH is the access path and no port needs
# opening on the LAN. Authentication is interactive by design: it hands out
# access to the machine, so an unattended run prints the command and stops
# rather than joining a tailnet on its own.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$_here/../../lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$_here/../manifest.sh"

fm_require_linux

do_check() {
  if ! fm_has_cmd tailscale; then
    fm_warn "tailscale missing"
    return 0
  fi
  fm_ok "tailscale $(tailscale version 2>/dev/null | head -1)"
  if tailscale status >/dev/null 2>&1; then
    # `status --json` pretty-prints with a space after the colon, so the
    # pattern must allow it or the identity extracts as empty.
    local identity
    identity="$(tailscale status --json 2>/dev/null | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4)"
    fm_ok "joined: ${identity:-identity unavailable}"
  else
    fm_warn "installed but not joined to a tailnet"
  fi
  return 0
}

do_install() {
  if fm_has_cmd tailscale; then
    fm_ok "tailscale already installed ($(tailscale version | head -1))"
  else
    fm_log "installing tailscale"
    # Tailscale's own installer adds the apt repo for this distro release and
    # installs the daemon. It is the vendor's documented path.
    curl -fsSL https://tailscale.com/install.sh | sh
    # The vendor's installer adds its own apt repo and installs from it, so
    # there is no fm_apt_install call to diff. The package it lands is the one
    # named here.
    fm_ledger_record tailscale tailscale
    fm_ok "tailscale installed"
  fi

  if tailscale status >/dev/null 2>&1; then
    fm_ok "already joined to a tailnet"
    return 0
  fi

  if [ "${NONINTERACTIVE:-0}" = "1" ]; then
    fm_warn "not joined — run this yourself: sudo tailscale up --ssh"
    return 0
  fi

  fm_log "joining the tailnet with SSH enabled"
  sudo tailscale up --ssh
}

do_uninstall() {
  if ! fm_has_cmd tailscale; then
    fm_skip "tailscale not installed"
    return 0
  fi
  # Logging out first releases the node from the tailnet; removing the package
  # alone leaves a stale machine in the admin console.
  sudo tailscale logout || fm_warn "tailscale logout failed — remove the node in the admin console"
  fm_apt_uninstall tailscale || return 1
}

fm_dispatch "$@"
