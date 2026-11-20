#!/usr/bin/env bash
#
# robot-sudo — give the fleet account on a robot passwordless sudo.
#
#   ./run.sh robot-sudo                 grant it to the account running this
#   ./run.sh robot-sudo --user anvil    grant it to another account
#   ./run.sh robot-sudo --dry-run       print the rule, write nothing
#   ./run.sh robot-sudo --remove        take it away again
#
# A robot is not a machine this repo provisions. It arrives on the vendor's OS
# with the vendor's accounts, and `fm device adopt` layers five things onto it —
# so there is no step chain to hang this on, and this is a verb an operator runs
# once on the robot itself.
#
# The grant is every command as any user. The fleet drives a robot's units, its
# camera daemons and its config over Zenoh, unattended, and a narrow list of
# commands kept failing at the next thing a deploy or a recovery needed. The
# operator accepted that this account can become root on the robot without a
# password; the confirm prompt below is where that is accepted again on each
# host.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$_here/../.." && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$FM_ROOT/lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$FM_ROOT/scripts/manifest.sh"

# The file the rule lands in. One file per concern, so removing this grant is
# deleting one path and never editing a file something else also writes.
SUDOERS_FILE="/etc/sudoers.d/fm-robot-services"

#: The writer that lets the agent keep the fleet file in step with the loader's.
#: The Anvil's domain and interface live in two files — the loader's
#: `.env.config`, owned by the account the agent runs as, and /etc/fm-comms.env,
#: owned by root because two systemd units read it. The agent writes both or
#: neither, so without this a paired write fails at staging with EACCES and the
#: two are stuck disagreeing, which is the defect the pairing exists to prevent.
#:
#: The agent calls it by this path, so it stays installed beside the rule.
WRITER_SOURCE="$FM_ROOT/templates/fm-comms-set"
WRITER="/usr/local/sbin/fm-comms-set"

usage() {
  cat <<'EOF'
robot-sudo — give an account passwordless sudo for every command here

Usage: ./run.sh robot-sudo [--user <name>] [--dry-run] [--remove]
       ./run.sh robot-sudo --help

  --user <name>   the account to grant it to (default: the one running this)
  --dry-run       print the rule that would be written, change nothing
  --remove        delete the rule

Grants NOPASSWD: ALL to the account, and installs the fleet-env writer at
/usr/local/sbin/fm-comms-set that the robot agent calls. Verify what an
account may do with:

  sudo -l -U <name>
EOF
}

# A username the system will accept, and that cannot smuggle anything into the
# sudoers file. Same shape add-user enforces when it creates one.
valid_name() {
  # LC_ALL=C: under a UTF-8 collation the ranges below can match uppercase and
  # other letters, as fm_machine_valid_name notes in lib.sh.
  local LC_ALL=C
  [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

rule_text() {
  local user="$1"
  cat <<EOF
# Written by fm-setup's robot-sudo verb. Do not edit by hand: re-run
#   ./run.sh robot-sudo --user $user
# to regenerate it, or --remove to take it away.
$user ALL=(ALL) NOPASSWD: ALL
EOF
}

# Install the rule, but only once sudo itself agrees it parses.
#
# A malformed file in /etc/sudoers.d breaks sudo for every account on the host,
# including the one that would have to fix it. So it is written to a temp file,
# checked with `visudo -c`, and only then moved into place — the check is the
# whole reason this is not two lines of `tee`.
install_rule() {
  local user="$1" tmp
  tmp="$(mktemp)"
  # The temp file holds no secret, but it does hold a grant: keep it unreadable
  # by anyone but its owner for the seconds it exists.
  chmod 0600 "$tmp"
  rule_text "$user" >"$tmp"

  if ! sudo visudo -c -f "$tmp" >/dev/null; then
    rm -f "$tmp"
    fm_err "the generated rule does not parse; nothing was written"
    return 1
  fi

  sudo install -m 0440 -o root -g root "$tmp" "$SUDOERS_FILE"
  rm -f "$tmp"
  fm_ok "wrote $SUDOERS_FILE"
  fm_info "check it with: sudo -l -U $user"
}

# Put the writer on the host before the rule. The agent runs it through sudo
# the moment the grant exists, so the file lands first and the rule second.
install_writer() {
  [ -f "$WRITER_SOURCE" ] || { fm_err "writer not found at $WRITER_SOURCE"; return 1; }
  sudo install -m 0755 -o root -g root "$WRITER_SOURCE" "$WRITER"
  fm_ok "installed $WRITER"
}

remove_rule() {
  if [ -e "$SUDOERS_FILE" ]; then
    sudo rm -f "$SUDOERS_FILE"
    fm_ok "removed $SUDOERS_FILE"
  else
    fm_ok "$SUDOERS_FILE is already absent"
  fi
  # The writer goes with the grant. Left behind, it reads as something still
  # in force.
  if [ -e "$WRITER" ]; then
    sudo rm -f "$WRITER"
    fm_ok "removed $WRITER"
  fi
}

main() {
  fm_require_linux

  local user="" dry=0 remove=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --user) user="${2:-}"; shift 2 || true ;;
      --dry-run) dry=1; shift ;;
      --remove) remove=1; shift ;;
      -h|--help) usage; return 0 ;;
      *) usage; return 1 ;;
    esac
  done

  if [ "$remove" = "1" ]; then
    fm_banner
    remove_rule
    return 0
  fi

  # The account behind the sudo that started this run, the same chain the users
  # step reads. $USER is set by a login shell and not by an unattended caller.
  user="${user:-${SUDO_USER:-${USER:-$(id -un)}}}"
  if ! valid_name "$user"; then
    fm_err "invalid username: '$user'"
    return 1
  fi
  if ! id -u "$user" >/dev/null 2>&1; then
    fm_err "no such account: $user"
    return 1
  fi

  if [ "$dry" = "1" ]; then
    # The rule alone on stdout, so a dry run can be piped straight into
    # `visudo -c -f -` or a file. Everything else goes to stderr.
    fm_log "$SUDOERS_FILE would hold:" >&2
    rule_text "$user"
    return 0
  fi

  fm_banner
  fm_log "granting $user passwordless sudo for every command"
  rule_text "$user"
  # Passwordless access is shown in full and then confirmed, per this repo's
  # rule for anything security-sensitive. NONINTERACTIVE declines it, so an
  # unattended run reports what it did not do rather than widening sudo quietly.
  if ! fm_confirm "write this rule to $SUDOERS_FILE?"; then
    fm_warn "declined; $SUDOERS_FILE unchanged"
    return 1
  fi
  install_writer || return 1
  install_rule "$user"
}

main "$@"
