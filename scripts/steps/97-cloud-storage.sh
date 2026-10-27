#!/usr/bin/env bash
# Provision private coordinator state and the lock shared with the legacy uploader.
set -euo pipefail
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$_here/../../lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$_here/../manifest.sh"
fm_require_linux

ENVFILE=/etc/fm-archive-uploader.env

# The coordinator's Zenoh service. Its binary comes with the machine-wide
# fm-tools (step fm-cli installs the storage-agent extra on a storage host), so
# this step writes only the unit, from the card's account.
AGENT_UNIT=fm-storage-agent.service
AGENT_UNIT_PATH=/etc/systemd/system/$AGENT_UNIT
AGENT_BIN="$FM_CLI_TOOL_DIR/fm-tools/bin/fm-storage-agent"

agent_unit() {
  cat <<UNIT
[Unit]
Description=First Motive Cloud Storage coordinator over Zenoh
After=network-online.target fm-archive-uploader.service
Wants=network-online.target

[Service]
Type=simple
User=$account
# The router endpoint, then the provider credentials and writer lock. Over SSH
# fm-data's archive.sh borrows the same files into this account's processes
# (sudo -n cat), one command at a time; the agent holds them for its lifetime.
EnvironmentFile=/etc/fm-comms.env
EnvironmentFile=$ENVFILE
EnvironmentFile=-/etc/fm-archive.env
ExecStart=$AGENT_BIN
Restart=always
RestartSec=5
# The agent writes only under the account's state, workspace and home (SSH
# known hosts for remote locations), so the system itself is read only to it.
NoNewPrivileges=yes
ProtectSystem=full
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
CapabilityBoundingSet=

[Install]
WantedBy=multi-user.target
UNIT
}

# root_only PATH — 0 when PATH and each directory above it up to /opt are
# root-owned and writable by no one else. The agent runs with the provider
# credentials, so whoever could replace its binary would hold them too.
root_only() {
  local path="$1" owner mode
  while [ "$path" != /opt ] && [ "$path" != / ]; do
    owner="$(stat -c '%U' "$path" 2>/dev/null)" || return 1
    mode="$(stat -c '%a' "$path" 2>/dev/null)" || return 1
    if [ "$owner" != root ] || [ $(( 8#$mode & 0022 )) -ne 0 ]; then
      fm_warn "$path is $owner mode $mode — not running the storage agent through it"
      return 1
    fi
    path="$(dirname "$path")"
  done
}

install_agent() {
  if [ ! -x "$AGENT_BIN" ]; then
    fm_warn "$AGENT_BIN is missing — run the fm-cli step to install fm-tools with its storage-agent extra"
    return 0
  fi
  if [ "$account" = root ]; then
    fm_err "the storage account is root — the agent runs as an unprivileged account"
    return 1
  fi
  root_only "$(readlink -f "$AGENT_BIN")" && root_only "$AGENT_BIN" || return 1
  if [ ! -f /etc/fm-comms.env ]; then
    fm_warn "/etc/fm-comms.env is missing — the storage agent needs fm-comms' router endpoint"
    return 0
  fi
  local unit changed=false
  unit="$(agent_unit)"
  if ! [ -f "$AGENT_UNIT_PATH" ] || [ "$(cat "$AGENT_UNIT_PATH")" != "$unit" ]; then
    printf '%s\n' "$unit" | sudo install -o root -g root -m 0644 /dev/stdin "$AGENT_UNIT_PATH"
    sudo systemctl daemon-reload
    changed=true
  fi
  sudo systemctl enable --quiet "$AGENT_UNIT"
  if [ "$changed" = true ]; then
    sudo systemctl restart "$AGENT_UNIT"
  else
    sudo systemctl start "$AGENT_UNIT"
  fi
  sudo systemctl is-active --quiet "$AGENT_UNIT" || { fm_err "storage agent is not active"; return 1; }
  publish_agent_key
}

# publish_agent_key — write the agent's public key to the card as
# storage.agent_key. Desktop reads it from the card over tailnet SSH and trusts
# only replies it signed, so the key travels by SSH, never by the fabric.
publish_agent_key() {
  local key card staged
  key="$(sudo -u "$account" "$AGENT_BIN" --public-key)" || { fm_err "the storage agent printed no key"; return 1; }
  if ! [[ "$key" =~ ^MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE[A-Za-z0-9+/]{86}==$ ]]; then
    fm_err "the storage agent's key is not a P-256 public key"
    return 1
  fi
  card="$(fm_machine_file)"
  [ "$(jq -r '.storage.agent_key // ""' "$card")" = "$key" ] && return 0
  staged="$(sudo mktemp "$(dirname "$card")/.machine.XXXXXX")" || return 1
  if jq --arg key "$key" '.storage.agent_key = $key' "$card" | sudo tee "$staged" >/dev/null &&
     sudo chmod --reference="$card" "$staged" && sudo chown --reference="$card" "$staged"; then
    sudo mv -- "$staged" "$card"
    fm_ok "storage agent key published on the card"
  else
    sudo rm -f -- "$staged"
    fm_err "could not write the storage agent key to $card"
    return 1
  fi
}

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
  if [ -f "$AGENT_UNIT_PATH" ] && [ "$(cat "$AGENT_UNIT_PATH")" = "$(agent_unit)" ] &&
     systemctl is-active --quiet "$AGENT_UNIT" &&
     [ -n "$(jq -r '.storage.agent_key // ""' "$(fm_machine_file)")" ]; then
    fm_ok "storage agent serving on zenoh, its key on the card"
  else
    fm_warn "storage agent is not installed or not running"
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
  install_agent || return 1
  do_check
}

do_uninstall() {
  if [ -f "$AGENT_UNIT_PATH" ]; then
    sudo systemctl disable --now --quiet "$AGENT_UNIT" || true
    sudo rm -f -- "$AGENT_UNIT_PATH"
    sudo systemctl daemon-reload
  fi
  fm_warn "coordinator state and writer lock retained; remove writer capabilities on the machine card to disable copies"
}

fm_dispatch "$@"
