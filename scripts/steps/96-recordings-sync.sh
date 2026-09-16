#!/usr/bin/env bash
#
# recordings-sync — point fm-sync.timer at the recorder and at the data root.
#
# fm_ros2 installs the timer and writes /etc/fm-sync.env with an empty source,
# which means "single box, nothing to pull". On a processor with its own
# recorder that default silently keeps every take on the rig. Found live on
# fm-ws-01 (2026-09-15): the timer had ticked every five minutes for weeks and
# never copied a bag. This step owns the two values that turn it on:
#
#   FM_SYNC_SOURCE  the recorder's recordings dir, user@host:path
#   FM_SYNC_DEST    <data root>/recordings — what the processor reads
#
# The destination comes from the identity card, not from ~ : the unit's default
# of ~/recordings is a directory the processor never looks at.
#
# The pull runs as fm over key-auth ssh, so the step makes sure fm has a key
# and reports whether the recorder accepts it. Installing that key on the
# recorder is a person's action on the other host; the step prints the key.
#
# The index the pull appends to can arrive root-owned from an archive restore;
# the step hands it to the fm group so the append does not fail.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$_here/../.." && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$FM_ROOT/lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$FM_ROOT/scripts/manifest.sh"

fm_require_linux

ENVFILE=/etc/fm-sync.env
SYNC_USER=fm
SOURCE="${FM_SYNC_SOURCE:-$FM_SYNC_SOURCE_DEFAULT}"
# The processor's own declared recordings dir outranks the card-derived root.
# Found live on fm-ws-01 (2026-09-16): /etc/fm-processor.env names
# /data/recordings while the card's data root is /opt/fm/data, so the first
# converge of this step pulled every take into a directory the processor never
# mounts. Until the two roots are reconciled, follow the consumer. Without a
# processor env the reading is 13-data-root's: the card, never FM_HOME.
PROCESSOR_ENV=/etc/fm-processor.env
processor_dir="$(sed -n 's/^FM_PROCESSOR_RECORDINGS_DIR=//p' "$PROCESSOR_ENV" 2>/dev/null | tail -1)"
DEST="${processor_dir:-$(FM_HOME='' fm_machine_workspace)/$FM_DATA_ROOT_NAME/recordings}"
INDEX="$DEST/sessions.jsonl"
KEY="/home/$SYNC_USER/.ssh/id_ed25519"

env_value() { sudo -n awk -F= -v key="$1" '$1 == key { print substr($0, index($0, "=") + 1) }' "$ENVFILE"; }

recorder_accepts_key() {
  sudo -n -u "$SYNC_USER" ssh -o BatchMode=yes -o ConnectTimeout=10 "${SOURCE%%:*}" true 2>/dev/null
}

do_check() {
  if [ ! -f "$ENVFILE" ]; then
    fm_warn "$ENVFILE missing — fm_ros2 has not installed fm-sync.timer yet"
    return 0
  fi
  if [ "$(env_value FM_SYNC_SOURCE)" = "$SOURCE" ] && [ "$(env_value FM_SYNC_DEST)" = "$DEST" ]; then
    fm_ok "fm-sync pulls $SOURCE -> $DEST"
  else
    fm_warn "fm-sync source/dest differ from $SOURCE -> $DEST"
  fi
  if recorder_accepts_key; then
    fm_ok "recorder accepts $SYNC_USER's key"
  else
    fm_warn "recorder refuses $SYNC_USER's key — install ${KEY}.pub on ${SOURCE%%:*}"
  fi
  if [ -f "$INDEX" ] && ! sudo -n -u "$SYNC_USER" test -w "$INDEX"; then
    fm_warn "$INDEX is not writable by $SYNC_USER"
  fi
  return 0
}

set_env() {  # key value
  if sudo -n grep -q "^$1=" "$ENVFILE"; then
    sudo -n sed -i -E "s|^$1=.*|$1=$2|" "$ENVFILE"
  else
    printf '%s=%s\n' "$1" "$2" | sudo -n tee -a "$ENVFILE" >/dev/null
  fi
}

do_install() {
  if [ ! -f "$ENVFILE" ]; then
    fm_skip "$ENVFILE missing — install fm-sync through fm_ros2 first, then converge again"
    return 0
  fi
  set_env FM_SYNC_SOURCE "$SOURCE"
  set_env FM_SYNC_DEST "$DEST"
  fm_ok "fm-sync pulls $SOURCE -> $DEST"

  if [ ! -f "$KEY" ]; then
    sudo -n -u "$SYNC_USER" ssh-keygen -q -t ed25519 -N "" -C "$SYNC_USER@$(hostname) sync" -f "$KEY"
    fm_ok "generated $KEY"
  fi
  # A file the sync appends to must be writable by the account that runs it.
  for f in "$INDEX" "$INDEX.lock"; do
    [ -f "$f" ] && sudo -n chgrp "$SYNC_USER" "$f" && sudo -n chmod g+w "$f"
  done
  if recorder_accepts_key; then
    fm_ok "recorder accepts $SYNC_USER's key"
  else
    fm_warn "recorder refuses $SYNC_USER's key — add this line to ${SOURCE%%:*}:~/.ssh/authorized_keys"
    sudo -n cat "${KEY}.pub"
  fi
}

do_uninstall() {
  if [ ! -f "$ENVFILE" ]; then
    fm_skip "$ENVFILE not present"
    return 0
  fi
  set_env FM_SYNC_SOURCE ""
  fm_ok "fm-sync back to single-box mode (no pull)"
  fm_warn "$KEY left in place; remove it from the recorder's authorized_keys by hand"
}

fm_dispatch "$@"
