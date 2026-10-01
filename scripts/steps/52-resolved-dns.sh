#!/usr/bin/env bash
#
# resolved-dns — give systemd-resolved global DNS servers on the rig.
#
# NetworkManager runs the rig's Wi-Fi with dns=systemd-resolved, but on fm-rec-01
# it did not push the Wi-Fi DNS servers to resolved. The only server resolved had
# was Tailscale's 100.100.100.100, which forwards to the host's own servers, so
# no name outside the tailnet resolved and every private-repo fetch by the
# updater failed (2026-10-01). A `resolvectl dns` fix is per link and lost on the
# next reconnect, so the servers go into a resolved.conf drop-in instead.
#
# The servers are the site's, from FM_RESOLVED_DNS_DEFAULT in the manifest; a rig
# on another network overrides them with FM_RESOLVED_DNS when it runs the step.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$_here/../../lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$_here/../manifest.sh"

fm_require_linux

DROPIN=/etc/systemd/resolved.conf.d/fm-dns.conf
SERVERS="${FM_RESOLVED_DNS:-$FM_RESOLVED_DNS_DEFAULT}"

render() {
  local ip
  # The value lands in a root-owned config; accept addresses only.
  for ip in $SERVERS; do
    [[ "$ip" =~ ^[0-9A-Fa-f.:]+$ ]] || { fm_err "not an IP address in FM_RESOLVED_DNS: $ip"; return 1; }
  done
  cat <<EOF
# Managed by fm-setup (52-resolved-dns.sh). NetworkManager did not push the
# Wi-Fi DNS servers to systemd-resolved, so they are set here for every link.
[Resolve]
DNS=$SERVERS
EOF
}

do_check() {
  local want
  if ! want="$(render)"; then
    fm_warn "FM_RESOLVED_DNS is not a list of IP addresses"
    return 0
  fi
  if [ "$(cat "$DROPIN" 2>/dev/null)" = "$want" ]; then
    fm_ok "$DROPIN sets DNS=$SERVERS"
  else
    fm_warn "$DROPIN missing or differs (want DNS=$SERVERS)"
  fi
  return 0
}

do_install() {
  local want
  want="$(render)"
  if [ "$(cat "$DROPIN" 2>/dev/null)" = "$want" ]; then
    fm_skip "$DROPIN already current"
    return 0
  fi
  sudo install -d -m 755 "$(dirname "$DROPIN")"
  printf '%s\n' "$want" | sudo tee "$DROPIN" >/dev/null
  sudo chmod 644 "$DROPIN"
  sudo systemctl restart systemd-resolved
  fm_ok "wrote $DROPIN (DNS=$SERVERS) and restarted systemd-resolved"
}

do_uninstall() {
  if [ ! -f "$DROPIN" ]; then
    fm_skip "$DROPIN not present"
    return 0
  fi
  sudo rm -f "$DROPIN"
  sudo systemctl restart systemd-resolved
  fm_ok "removed $DROPIN"
}

fm_dispatch "$@"
