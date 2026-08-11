#!/usr/bin/env bash
#
# udev-rules — stable device names and group access for the capture sensors.
#
# Without these, a tactile glove is /dev/ttyUSB0 on one boot and /dev/ttyUSB2 on
# the next, and a RealSense camera needs root to open. Both failures show up
# mid-session, which is the worst time to find them.
#
# The rules file is a template in this repo rather than a heredoc, so a device
# can be added by editing a rules file and nothing else.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$_here/../.." && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$FM_ROOT/lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$FM_ROOT/scripts/manifest.sh"

fm_require_linux

SOURCE="$FM_ROOT/templates/udev/99-fm-sensors.rules"
TARGET=/etc/udev/rules.d/99-fm-sensors.rules

do_check() {
  if [ ! -f "$TARGET" ]; then
    fm_warn "$TARGET missing"
  elif sudo cmp -s "$SOURCE" "$TARGET"; then
    fm_ok "$TARGET current"
  else
    fm_warn "$TARGET differs from the template"
  fi

  # plugdev is what the rules grant to, so a user outside it still cannot open
  # the sensors however correct the rules are.
  if getent group plugdev >/dev/null 2>&1; then
    fm_ok "group plugdev: $(fm_group_members plugdev | tr '\n' ' ')"
  else
    fm_warn "group plugdev missing"
  fi
  return 0
}

# A rule that grants to plugdev does nothing for someone who is not in it, and
# the failure looks like a broken camera rather than a missing group. This runs
# on every install, not only when the rules file changes: the roster grows after
# provisioning, and a person added later needs the group just as much.
ensure_plugdev() {
  if ! getent group plugdev >/dev/null 2>&1; then
    fm_warn "group plugdev does not exist — the rules grant to a group nobody is in"
    return 0
  fi
  local u
  while IFS= read -r u; do
    if id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -qx plugdev; then
      fm_ok "$u is in plugdev"
    else
      sudo usermod -aG plugdev "$u"
      fm_warn "$u added to plugdev — log out and back in for it to take effect"
    fi
  done < <(fm_group_members "$FM_GROUP")
}

do_install() {
  [ -f "$SOURCE" ] || { fm_err "template missing: $SOURCE"; return 1; }

  if sudo cmp -s "$SOURCE" "$TARGET" 2>/dev/null; then
    fm_ok "$TARGET current"
  else
    fm_log "installing $TARGET"
    sudo install -m 0644 "$SOURCE" "$TARGET"
    sudo udevadm control --reload-rules
    # Re-triggers the rules against devices already plugged in, so a sensor that
    # was connected before this ran picks up its symlink without a replug.
    sudo udevadm trigger
    fm_ok "udev rules installed and triggered"
  fi

  ensure_plugdev
}

do_uninstall() {
  if [ -f "$TARGET" ]; then
    sudo rm -f "$TARGET"
    sudo udevadm control --reload-rules
    fm_ok "$TARGET removed"
  else
    fm_skip "$TARGET not present"
  fi
}

fm_dispatch "$@"
