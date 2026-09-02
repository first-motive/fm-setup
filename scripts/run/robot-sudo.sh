#!/usr/bin/env bash
#
# robot-sudo — let the fleet restart its own services on a robot, without a password.
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
# What it grants is deliberately small. Deploying a new agent is `git pull` in a
# checkout the account already owns, then one `systemctl restart` it does not.
# That restart is the whole reason a password gets typed, and typing it is what
# stops `fm device update` from working unattended. So the rule names those
# units, those verbs, and nothing else: this account can restart the fleet's own
# services and cannot become root.
#
# On a workcell the vendor still supports, that distinction is the point. An
# `ALL=(ALL) NOPASSWD:ALL` here would hand a fleet account the run of a machine
# Anvil and Almond are responsible for.

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

# The services the fleet owns on a robot host, and therefore the only ones this
# rule reaches. fm-robot-agent answers the verb set; fm-zenoh-bridge carries the
# robot's telemetry onto the fabric. A config write that touches the transport
# restarts both, which is why both are here.
FM_UNITS=(fm-robot-agent fm-zenoh-bridge)

# What may be done to them. `restart`, `start` and `stop` are the deploy path;
# `status` and `is-active` are how a caller finds out whether it worked.
#
# `daemon-reload` is absent on purpose: it re-reads every unit file on the host,
# including the vendor's, and nothing in a deploy needs it — an unchanged unit
# file is the normal case, and installing a changed one is install.sh's job,
# which asks for a password like any other install.
FM_VERBS=(start stop restart status is-active)

#: The writer that lets the agent keep the fleet file in step with the loader's.
#: The Anvil's domain and interface live in two files — the loader's
#: `.env.config`, owned by the account the agent runs as, and /etc/fm-comms.env,
#: owned by root because two systemd units read it. The agent writes both or
#: neither, so without this a paired write fails at staging with EACCES and the
#: two are stuck disagreeing, which is the defect the pairing exists to prevent.
#:
#: Granting this one path rather than the file itself: the writer takes a key and
#: a value, accepts three keys, checks each value, and reads no path from its
#: caller. An account that reaches it can change three values and nothing else.
WRITER_SOURCE="$FM_ROOT/templates/fm-comms-set"
WRITER="/usr/local/sbin/fm-comms-set"

usage() {
  cat <<'EOF'
robot-sudo — let the fleet restart its own services here, without a password

Usage: ./run.sh robot-sudo [--user <name>] [--dry-run] [--remove]
       ./run.sh robot-sudo --help

  --user <name>   the account to grant it to (default: the one running this)
  --dry-run       print the rule that would be written, change nothing
  --remove        delete the rule

Grants NOPASSWD for start/stop/restart/status/is-active on fm-robot-agent and
fm-zenoh-bridge, plus the fleet-env writer at /usr/local/sbin/fm-comms-set, and
nothing else. Verify what an account may do with:

  sudo -l -U <name>
EOF
}

# A username the system will accept, and that cannot smuggle anything into the
# sudoers file. Same shape add-user enforces when it creates one.
valid_name() {
  case "$1" in
    [a-z_][a-z0-9_-]*) [ "${#1}" -le 32 ] ;;
    *) return 1 ;;
  esac
}

# Where systemctl actually is on this host.
#
# A sudoers rule matches the command by absolute path, so a guessed path grants
# nothing and fails at the moment someone needs it. Resolved here rather than
# hardcoded: /usr/bin/systemctl on the Anvil's Ubuntu, /bin/systemctl on hosts
# that never merged /bin.
systemctl_path() {
  local path
  # FM_SYSTEMCTL names it outright, for a host that keeps systemctl somewhere
  # unusual and for the test suite, which runs where systemd does not.
  if [ -n "${FM_SYSTEMCTL:-}" ]; then
    printf '%s\n' "$FM_SYSTEMCTL"
    return 0
  fi
  path="$(command -v systemctl 2>/dev/null || true)"
  [ -n "$path" ] || { fm_err "systemctl is not on PATH — is this a systemd host?"; return 1; }
  # A symlinked /bin/systemctl and the /usr/bin it points at are different
  # strings to sudo, and only the one the caller types is matched.
  readlink -f "$path" 2>/dev/null || printf '%s\n' "$path"
}

# The rule itself: one line per unit-and-verb pair.
#
# Spelled out rather than globbed. `systemctl restart fm-*` would also match a
# unit somebody adds later under that prefix, and a grant that widens on its own
# is not a grant anybody reviewed.
rule_text() {
  local user="$1" systemctl="$2" unit verb
  local -a allowed=()
  for unit in "${FM_UNITS[@]}"; do
    for verb in "${FM_VERBS[@]}"; do
      allowed+=("$systemctl $verb $unit")
    done
  done
  allowed+=("$WRITER")

  cat <<EOF
# Written by fm-setup's robot-sudo verb. Do not edit by hand: re-run
#   ./run.sh robot-sudo --user $user
# to regenerate it, or --remove to take it away.
#
# $user may restart the fleet's own services on this robot and do nothing else
# as root. The vendor's OS, packages and units are untouched by this rule.
$user ALL=(root) NOPASSWD: \\
EOF

  # One command per line: sudoers continues a rule across lines on a trailing
  # backslash and ends it on the line without one.
  local index last=$(( ${#allowed[@]} - 1 ))
  for index in "${!allowed[@]}"; do
    if [ "$index" -eq "$last" ]; then
      printf '    %s\n' "${allowed[index]}"
    else
      printf '    %s, \\\n' "${allowed[index]}"
    fi
  done
}

# Install the rule, but only once sudo itself agrees it parses.
#
# A malformed file in /etc/sudoers.d breaks sudo for every account on the host,
# including the one that would have to fix it. So it is written to a temp file,
# checked with `visudo -c`, and only then moved into place — the check is the
# whole reason this is not two lines of `tee`.
# Put the writer on the host before the rule that names it.
#
# A sudoers rule pointing at a path that does not exist grants nothing and fails
# at the moment somebody needs it, so the file lands first and the rule second.
install_writer() {
  [ -f "$WRITER_SOURCE" ] || { fm_err "writer not found at $WRITER_SOURCE"; return 1; }
  sudo install -m 0755 -o root -g root "$WRITER_SOURCE" "$WRITER"
  fm_ok "installed $WRITER"
}

install_rule() {
  local user="$1" systemctl="$2" tmp
  tmp="$(mktemp)"
  # The temp file holds no secret, but it does hold a grant: keep it unreadable
  # by anyone but its owner for the seconds it exists.
  chmod 0600 "$tmp"
  rule_text "$user" "$systemctl" >"$tmp"

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

remove_rule() {
  if [ -e "$SUDOERS_FILE" ]; then
    sudo rm -f "$SUDOERS_FILE"
    fm_ok "removed $SUDOERS_FILE"
  else
    fm_ok "$SUDOERS_FILE is already absent"
  fi
  # The writer goes with the grant. Left behind it is a root-owned script no
  # account may run, which reads as something still in force.
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

  local systemctl
  systemctl="$(systemctl_path)" || return 1

  if [ "$dry" = "1" ]; then
    # The rule alone on stdout, so a dry run can be piped straight into
    # `visudo -c -f -` or a file. Everything else goes to stderr.
    fm_log "$SUDOERS_FILE would hold:" >&2
    rule_text "$user" "$systemctl"
    return 0
  fi

  fm_banner
  fm_log "granting $user passwordless control of ${FM_UNITS[*]}"
  rule_text "$user" "$systemctl"
  # Passwordless access is shown in full and then confirmed, per this repo's
  # rule for anything security-sensitive. NONINTERACTIVE declines it, so an
  # unattended run reports what it did not do rather than widening sudo quietly.
  if ! fm_confirm "write this rule to $SUDOERS_FILE?"; then
    fm_warn "declined; $SUDOERS_FILE unchanged"
    return 1
  fi
  install_writer || return 1
  install_rule "$user" "$systemctl"
}

main "$@"
