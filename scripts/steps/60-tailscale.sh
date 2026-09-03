#!/usr/bin/env bash
#
# tailscale — the network every machine is reached on.
#
# Brought up with --ssh, so Tailscale SSH is the access path and no port needs
# opening on the LAN. Authentication is interactive by design: it hands out
# access to the machine, so an unattended run prints the command and stops
# rather than joining a tailnet on its own.
#
# The vendor's installer runs as root, so it is fetched to a file, checksummed
# against the manifest pin, and told which version to install. A pipe straight
# into sh leaves nothing for a check to hold.

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
    # Read the JSON as JSON. A `grep | head -1` chain in an assignment under
    # pipefail can abort the step with 141 when head closes the pipe early; jq
    # is in the base packages, which step 10 installs before this one runs.
    local identity
    identity="$(tailscale status --json --peers=false 2>/dev/null | jq -r '.Self.DNSName // empty')"
    fm_ok "joined: ${identity:-identity unavailable}"
  else
    fm_warn "installed but not joined to a tailnet"
  fi
  return 0
}

# Fetch, verify, and run Tailscale's installer. Split out so this function owns
# the temp file's whole life, matching install_uv in 15-fm-cli.sh.
install_tailscale() {
  local script rc=0
  script="$(mktemp)"

  # One place creates the temp file and one place removes it, matching
  # install_uv in 15-fm-cli.sh. Not a `trap … RETURN`: that trap is not scoped
  # to the function that sets it, so it fires again when the caller returns.
  _install_tailscale_inner "$script" || rc=$?
  rm -f "$script"
  return "$rc"
}

_install_tailscale_inner() {
  local script="$1"

  curl -fsSL --proto '=https' https://tailscale.com/install.sh -o "$script" \
    || { fm_err "could not fetch the tailscale installer"; return 1; }

  if ! fm_verify_checksum "$script" "$FM_TAILSCALE_INSTALLER_SHA256"; then
    fm_err "tailscale rewrites this installer in place, so any edit upstream lands here"
    fm_err "re-derive the checksum and update FM_TAILSCALE_INSTALLER_SHA256 in"
    fm_err "scripts/manifest.sh, after reading the script — do not bypass this check:"
    fm_err "  curl -fsSL https://tailscale.com/install.sh | sha256sum"
    return 1
  fi
  fm_ok "tailscale installer checksum verified"

  # The vendor's documented path: the installer adds the apt repo for this
  # distro release and installs the daemon. TAILSCALE_VERSION is the
  # installer's own knob for pinning the package it lands.
  TAILSCALE_VERSION="$FM_TAILSCALE_VERSION" sh "$script" \
    || { fm_err "the tailscale installer failed"; return 1; }
}

do_install() {
  if fm_has_cmd tailscale; then
    fm_ok "tailscale already installed ($(tailscale version | head -1))"
  else
    fm_log "installing tailscale $FM_TAILSCALE_VERSION"
    install_tailscale || return 1
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
