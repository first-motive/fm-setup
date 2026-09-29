#!/usr/bin/env bash
# Provision private coordinator state and the lock shared with the legacy uploader.
set -euo pipefail
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$_here/../../lib.sh"
fm_require_linux

ENVFILE=/etc/fm-archive-uploader.env

configuration() {
  local card
  card="$(fm_machine_file)"
  account="$(jq -er '.storage.account' "$card")"
  state="$(jq -er '.storage.state_dir' "$card")"
  root="$(sudo -n awk -F= '$1 == "FM_ARCHIVE_UPLOADER_STATE_DIR" {print substr($0, index($0, "=") + 1)}' "$ENVFILE")"
  getent passwd "$account" >/dev/null
  for path in "$state" "$root"; do
    [[ "$path" = /* && "$path" != *$'\n'* && "$path" != *"'"* ]] || return 1
    [ "$(realpath -m -- "$path")" = "$path" ] || return 1
  done
  [ -d "$root" ] && [ ! -L "$ENVFILE" ] && [ -f "$ENVFILE" ]
  lock="$root/.fm-archive-writer.lock"
  [ ! -L "$lock" ]
}

do_check() {
  if ! configuration; then
    fm_warn "cloud storage configuration is missing or unsafe"
    return 0
  fi
  if [ "$(stat -c '%U:%a' "$state" 2>/dev/null)" = "$account:700" ] &&
     [ "$(stat -c '%U:%a' "$lock" 2>/dev/null)" = "$account:600" ] &&
     sudo -n grep -Fxq "FM_ARCHIVE_WRITER_LOCK='$lock'" "$ENVFILE" &&
     sudo systemctl is-active --quiet fm-archive-uploader.service; then
    fm_ok "private coordinator state and shared writer lock configured"
  else
    fm_warn "cloud storage provisioning is incomplete"
  fi
}

do_install() {
  configuration || { fm_err "cloud storage configuration is missing or unsafe"; return 1; }
  sudo install -d -m 0700 -o "$account" -- "$state"
  # Never replace the inode of a lock which an uploader can already hold.
  if [ ! -e "$lock" ]; then
    sudo -u "$account" sh -c 'umask 077; set -C; : > "$1"' sh "$lock"
  fi
  if [ ! -f "$lock" ] || [ "$(stat -c '%U:%a' "$lock")" != "$account:600" ]; then
    fm_err "shared writer lock must be a private file owned by the coordinator"
    return 1
  fi
  if ! sudo -n grep -Fxq "FM_ARCHIVE_WRITER_LOCK='$lock'" "$ENVFILE"; then
    local temporary
    temporary="$(sudo mktemp /etc/.fm-storage.XXXXXX)"
    sudo awk '!/^FM_ARCHIVE_WRITER_LOCK=/' "$ENVFILE" | sudo tee "$temporary" >/dev/null
    printf "FM_ARCHIVE_WRITER_LOCK='%s'\n" "$lock" | sudo tee -a "$temporary" >/dev/null
    sudo chmod --reference="$ENVFILE" "$temporary"
    sudo chown --reference="$ENVFILE" "$temporary"
    sudo mv -- "$temporary" "$ENVFILE"
    sudo systemctl restart fm-archive-uploader.service
  fi
  if ! sudo systemctl is-active --quiet fm-archive-uploader.service; then
    sudo systemctl restart fm-archive-uploader.service
  fi
  sudo systemctl is-active --quiet fm-archive-uploader.service ||
    { fm_err "archive uploader is not active"; return 1; }
  do_check
}

do_uninstall() {
  fm_warn "coordinator state and writer lock retained; remove writer capabilities on the machine card to disable copies"
}

fm_dispatch "$@"
