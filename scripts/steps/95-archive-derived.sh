#!/usr/bin/env bash
# archive-derived — explicitly enable the processor's derived archive writes.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$_here/../.." && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$FM_ROOT/lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$FM_ROOT/scripts/manifest.sh"

fm_require_linux

ENVFILE=/etc/fm-archive-uploader.env
UNIT="fm-archive-uploader.service"
FLAG=FM_ARCHIVE_UPLOADER_DERIVED_ENABLED
EDIT_TMP=""
BACKUP_TMP=""

cleanup() {
  [ -z "$EDIT_TMP" ] || sudo -n rm -f -- "$EDIT_TMP" 2>/dev/null || true
  [ -z "$BACKUP_TMP" ] || sudo -n rm -f -- "$BACKUP_TMP" 2>/dev/null || true
}
trap cleanup EXIT

env_value() { sudo -n awk -F= -v key="$1" '$1 == key { print substr($0, index($0, "=") + 1) }' "$ENVFILE"; }

validate_env() {
  local count key value expected
  [ -f "$ENVFILE" ] || { fm_err "$ENVFILE is missing"; return 1; }
  [ ! -L "$ENVFILE" ] || { fm_err "$ENVFILE is a symlink"; return 1; }
  [ "$(sudo -n stat -c '%a' "$ENVFILE")" = 600 ] || { fm_err "$ENVFILE must have mode 600"; return 1; }
  for key in "$FLAG" FM_ARCHIVE_UPLOADER_ENABLED FM_ARCHIVE_UPLOADER_DELETE_ENABLED; do
    count="$(sudo -n awk -v key="$key" '$0 ~ "^[[:space:]]*(export[[:space:]]+)?" key "[[:space:]]*=" { n++ } END { print n + 0 }' "$ENVFILE")" || return 1
    [ "$count" = 1 ] || { fm_err "$ENVFILE must contain exactly one $key entry"; return 1; }
    value="$(env_value "$key")" || return 1
    case "$key" in
      "$FLAG") case "$value" in true|false) continue ;; esac; expected='true or false' ;;
      FM_ARCHIVE_UPLOADER_ENABLED) expected=true ;;
      FM_ARCHIVE_UPLOADER_DELETE_ENABLED) expected=false ;;
    esac
    [ "$value" = "$expected" ] || { fm_err "$key must be $expected"; return 1; }
  done
}

capture_original() {
  BACKUP_TMP="$(sudo -n mktemp "$(dirname "$ENVFILE")/.fm-archive-derived.XXXXXX")" || return 1
  sudo -n cp -p -- "$ENVFILE" "$BACKUP_TMP"
}

restore_original() {
  sudo -n mv -fT -- "$BACKUP_TMP" "$ENVFILE" || return 1
  BACKUP_TMP=""
}

replace_flag() {
  local value="$1"
  EDIT_TMP="$(sudo -n mktemp "$(dirname "$ENVFILE")/.fm-archive-derived.XXXXXX")" || return 1
  sudo -n sed -E "s/^${FLAG}=.*/${FLAG}=${value}/" "$ENVFILE" | sudo -n tee "$EDIT_TMP" >/dev/null || return 1
  sudo -n chown --reference="$BACKUP_TMP" "$EDIT_TMP" || return 1
  sudo -n chmod --reference="$BACKUP_TMP" "$EDIT_TMP" || return 1
  sudo -n mv -fT -- "$EDIT_TMP" "$ENVFILE" || return 1
  EDIT_TMP=""
}

provider_preflight() {
  fm_log "running provider preflight before enabling derived uploads"
  fm archive preflight --json
}

do_check() {
  local flag
  if ! validate_env 2>/dev/null; then
    fm_warn "archive uploader configuration is missing or unsafe"
    return 0
  fi
  flag="$(env_value "$FLAG")"
  if sudo -n systemctl cat "$UNIT" >/dev/null 2>&1; then
    fm_ok "$FLAG=$flag ($UNIT installed)"
    if [ "$flag" = true ]; then
      if [ "$(sudo -n systemctl is-active "$UNIT" 2>/dev/null)" = active ]; then
        fm_ok "$UNIT active"
      else
        fm_warn "$UNIT is not active"
      fi
    fi
  else
    fm_warn "$UNIT is not installed"
  fi
  return 0
}

set_enabled() {
  local desired="$1" old
  validate_env || return 1
  sudo -n systemctl cat "$UNIT" >/dev/null 2>&1 || { fm_err "$UNIT is not installed; install the uploader through fm_ros2 first"; return 1; }
  old="$(env_value "$FLAG")"
  if [ "$old" = "$desired" ] && sudo -n systemctl is-active --quiet "$UNIT"; then
    fm_ok "$FLAG already $desired and $UNIT active"
    return 0
  fi
  if [ "$desired" = true ]; then provider_preflight || return 1; fi
  capture_original || return 1
  replace_flag "$desired" || return 1
  if ! sudo -n systemctl restart "$UNIT" || ! sudo -n systemctl is-active --quiet "$UNIT"; then
    fm_warn "uploader restart failed; restoring $FLAG=$old"
    restore_original || return 1
    if ! sudo -n systemctl restart "$UNIT" || ! sudo -n systemctl is-active --quiet "$UNIT"; then
      fm_err "original configuration restored, but uploader recovery failed"
    fi
    return 1
  fi
  fm_ok "$FLAG=$desired and $UNIT active; queue state preserved"
}

do_install() { set_enabled true; }
do_uninstall() { set_enabled false; }

fm_dispatch "$@"
