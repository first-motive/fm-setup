#!/usr/bin/env bash
#
# no-snap — a workstation with no snapd on it, and Firefox from apt.
#
# The workstation is a box people work on, and snap's confinement is in the way
# of most of that work: a snap Firefox cannot open a file outside the home
# directory, so a recording under /data is unreachable from it, and a snapped
# browser cannot see a local dev server the way an apt one can. The same
# confinement is why 30-docker.sh takes Docker from Docker's own repo.
#
# Removing snapd is not enough on its own. Ubuntu's own packages recommend it,
# so the next `apt install` that happens to pull one of them brings snapd back;
# the apt preference below is what makes the removal hold. Firefox is the reason
# the removal is felt at all — the archive's `firefox` package is a shim that
# installs the snap — so this step also adds Mozilla's apt repo, which ships a
# real .deb.
#
# It converges as well as installs: fm-ws-01 was built by hand before the
# autoinstall seed existed and still has snapd on it.
#
# Sources: https://support.mozilla.org/en-US/kb/install-firefox-linux

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$_here/../../lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$_here/../manifest.sh"

fm_require_linux

KEYRING=/etc/apt/keyrings/packages.mozilla.org.asc
SOURCES=/etc/apt/sources.list.d/mozilla.sources
MOZILLA_PIN=/etc/apt/preferences.d/mozilla-firefox.pref
SNAP_PIN=/etc/apt/preferences.d/no-snapd.pref

do_check() {
  if fm_has_pkg snapd; then fm_warn "snapd installed"; else fm_ok "no snapd"; fi
  if [ -f "$SNAP_PIN" ]; then fm_ok "snapd pinned out of apt"; else fm_warn "snapd is not pinned out — apt may reinstall it"; fi
  if [ -f "$SOURCES" ]; then fm_ok "mozilla apt repo present"; else fm_warn "mozilla apt repo missing"; fi
  if fm_has_pkg firefox; then
    # Which firefox matters more than whether: the archive's package of the same
    # name is a shim that installs the snap, and says so in its version.
    if is_snap_shim; then
      fm_warn "firefox is the archive's snap shim ($(firefox_version))"
    else
      fm_ok "firefox from apt ($(firefox_version))"
    fi
  else
    fm_warn "firefox missing"
  fi
  return 0
}

firefox_version() { dpkg-query -W -f='${Version}' firefox 2>/dev/null; }

# Ubuntu's transitional package carries `snap` in its version (1:1snap1-0ubuntu5)
# and Mozilla's builds never do, which is the only difference visible from dpkg:
# both packages are called `firefox` and both provide the same binary name.
is_snap_shim() {
  case "$(firefox_version)" in *snap*) return 0 ;; *) return 1 ;; esac
}

# Pin snapd to a priority apt will never satisfy. Removal alone does not hold:
# ubuntu-desktop and friends recommend snapd, so any later install can bring it
# back without anyone asking for it.
write_snap_pin() {
  sudo tee "$SNAP_PIN" >/dev/null <<'EOF'
# Written by fm-setup (scripts/steps/25-no-snap.sh). A negative priority is a
# refusal: apt will not install snapd to satisfy a recommendation, or at all.
Package: snapd
Pin: release a=*
Pin-Priority: -1
EOF
}

remove_snaps() {
  fm_has_cmd snap || return 0
  # Snaps come off in dependency order — a base cannot go while something is
  # mounted on it — and `snap remove` reports that rather than resolving it. So
  # this makes passes until a pass removes nothing, bounded so a snap that
  # genuinely refuses cannot spin here forever.
  local name removed
  for _ in 1 2 3; do
    removed=0
    while read -r name; do
      [ -n "$name" ] || continue
      if sudo snap remove --purge "$name" >/dev/null 2>&1; then
        fm_info "removed snap: $name"
        removed=1
      fi
    done < <(snap list 2>/dev/null | awk 'NR > 1 { print $1 }')
    [ "$removed" = 1 ] || break
  done
}

add_mozilla_repo() {
  fm_log "adding Mozilla's apt repo"
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL --proto '=https' "$FM_MOZILLA_KEY_URL" -o "$KEYRING"
  sudo chmod a+r "$KEYRING"

  # The key is checked by fingerprint, not taken on TLS alone: this key signs
  # the browser every person on this machine will type passwords into, and a
  # repo signed by the wrong key installs anything it likes as root.
  local fpr
  fpr="$(gpg --show-keys --with-colons "$KEYRING" 2>/dev/null | awk -F: '/^fpr:/ { print $10; exit }')"
  if [ "$fpr" != "$FM_MOZILLA_KEY_FPR" ]; then
    fm_err "Mozilla signing key fingerprint mismatch"
    fm_err "  expected $FM_MOZILLA_KEY_FPR"
    fm_err "  actual   ${fpr:-<unreadable>}"
    sudo rm -f "$KEYRING"
    return 1
  fi
  fm_ok "signing key matches the pinned fingerprint"

  sudo tee "$SOURCES" >/dev/null <<EOF
Types: deb
URIs: $FM_MOZILLA_APT_URL
Suites: mozilla
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: $KEYRING
EOF

  # Without this, apt prefers the archive's higher version number, which is the
  # snap shim — the package this step exists to avoid.
  # Named packages rather than `*`: the priority this grants is the highest apt
  # has, and it should reach the browser this step installs and nothing else
  # Mozilla might publish beside it later.
  sudo tee "$MOZILLA_PIN" >/dev/null <<'EOF'
# Written by fm-setup (scripts/steps/25-no-snap.sh). Mozilla's builds win over
# the archive's same-named package, which is a shim that installs the snap.
Package: firefox firefox-l10n-* firefox-locale-*
Pin: origin packages.mozilla.org
Pin-Priority: 1000
EOF
  sudo apt-get update
}

do_install() {
  write_snap_pin

  if fm_has_pkg snapd; then
    remove_snaps
    fm_log "purging snapd"
    sudo DEBIAN_FRONTEND=noninteractive apt-get purge -y snapd
    # What purge leaves behind. These are snap's own state directories, not
    # anyone's documents: no user data lives here that is not a snap's.
    sudo rm -rf /var/cache/snapd /var/snap /snap
    fm_ok "snapd removed"
  else
    fm_ok "no snapd"
  fi

  [ -f "$SOURCES" ] || add_mozilla_repo

  # The shim first: it is `firefox` too, and apt will not replace it with
  # Mozilla's build while it is the version that is already installed.
  if fm_has_pkg firefox && is_snap_shim; then
    fm_log "removing the archive's snap shim"
    sudo DEBIAN_FRONTEND=noninteractive apt-get purge -y firefox
  fi

  if fm_has_pkg firefox; then
    fm_ok "firefox present ($(firefox_version))"
  else
    fm_log "apt install firefox (packages.mozilla.org)"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y firefox
    fm_ok "firefox installed from apt"
  fi
}

do_uninstall() {
  if fm_has_pkg firefox; then
    fm_log "apt remove firefox"
    sudo apt-get remove -y firefox
  fi
  sudo rm -f "$SOURCES" "$KEYRING" "$MOZILLA_PIN" "$SNAP_PIN"
  # snapd is not put back. Reinstalling it would re-mount the confinement this
  # step exists to remove, on a machine whose owner asked for the opposite, and
  # nothing on the workstation depends on it. `sudo apt-get install snapd` is
  # the one line to type if it is genuinely wanted again.
  fm_warn "snapd not reinstalled — the apt pin is gone, so 'sudo apt-get install snapd' now works"
}

fm_dispatch "$@"
