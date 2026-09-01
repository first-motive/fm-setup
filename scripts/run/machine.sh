#!/usr/bin/env bash
#
# machine — this host's identity card: write it, read it, check it, remove it.
#
#   ./run.sh machine init --name fm-rec-01     # write the card
#   ./run.sh machine show --json               # read it back
#   ./run.sh machine doctor                    # check it against the schema
#   ./run.sh machine reset                     # remove it
#
# The card is the one place a machine says what it is. Its name is the
# hostname, the mDNS name, the tailnet name, and the stem the ROS namespace is
# derived from; its workspace is where every First Motive checkout lives; its
# transport is the middleware profile every process on the host sources. Nothing
# downstream types those facts a second time — fm-comms renders zenoh's json5
# from this file, fm_ros2 derives its namespace and unit names from it, fm-docker
# builds its compose environment from it, and fm-desktop reads the workspace out
# of it instead of assuming ~/fm_ros2.
#
# This file is the noun; the first argument is the verb. `fm machine init`
# reaches here as `machine.sh init`, because fm-tools forwards every remaining
# argument to the script a repo mounts. A repo therefore mounts nouns, and the
# verbs live where the work does.
#
# Exit codes follow the CLI's contract: 0 success, 2 usage, 3 precondition.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$_here/../.." && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$FM_ROOT/lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$FM_ROOT/scripts/manifest.sh"

EX_USAGE=2
EX_PRECONDITION=3

NAME=""
ROLE=""
FLEET=""
TRANSPORT=""
WORKLOAD=""
ROBOT=""
WORKSPACE=""
# Distinguishes "the caller asked for this workspace" from "the card had one".
# Only the second is converged onto the new default; a passed --workspace is a
# deliberate choice and is written exactly as given, even back into a home.
WORKSPACE_EXPLICIT=0
AS_JSON=0
DRY_RUN=0
ASSUME_YES=0

usage() {
  cat <<EOF
machine — this host's identity card

Usage: ./run.sh machine <verb> [options]

Verbs:
  init      write (or repair) the card, then align the hostname to it
  show      print the card
  doctor    check the card against the schema and this host
  reset     remove the card

Options:
  --name <fm-abbrev-nn>   machine name (default: derived from the role, 01)
  --role <role>           ${FM_MACHINE_ROLES[*]} (default: detected)
  --fleet <name>          population this machine joins (default: $FM_MACHINE_FLEET_DEFAULT)
  --transport <profile>   ${FM_MACHINE_TRANSPORTS[*]} (default: ${FM_MACHINE_TRANSPORTS[0]})
  --workload <kind>       ${FM_MACHINE_WORKLOADS[*]} — what this machine does in
                          the stack. Optional, but a machine on the zenoh
                          transport needs one to get a bridge: a Mac is
                          \`cockpit\`. --workload none clears it.
  --robot <kind>          ${FM_MACHINE_ROBOTS[*]} — which robot this machine
                          is. Required on the robot role, refused on any other.
  --workspace <path>      parent directory for every checkout
                          (default: $FM_MACHINE_WORKSPACE_DEFAULT)
  --json                  machine-readable output
  --dry-run               print what would be written, touch nothing
  -y, --yes               skip confirmations
  -h, --help              this text

The card lives at $(fm_machine_file).

init is idempotent and repairs in place: run it again after editing a field and
it rewrites the card and re-aligns the hostname, keeping the two from drifting
apart. Fields you do not pass keep the value already on the card.
EOF
}

# --- Validation -------------------------------------------------------------
#
# The rules themselves live in lib.sh, because `flash` writes a card into a
# cloud-init seed as well and a second copy of them would let the two callers
# disagree about what a valid card is. These are thin names over that one set.

# True when a workspace path sits inside somebody's home directory.
#
# The card names one workspace for the whole host, and a home directory is mode
# 700 on Ubuntu — so a card pointing into one hands every other account a
# workspace it cannot enter. That is how a machine ends up needing an FM_HOME
# export in nine shell files, and it is invisible from the administrator's own
# session, where every path resolves perfectly.
#
# Matched on the path rather than on the invoking user's $HOME, because doctor is
# read by whoever happens to run it and a card naming /home/fm/fm is just as
# wrong when fm is the one reading it.
workspace_in_home() { # path
  case "$1" in
    /home/*|/root|/root/*|/Users/*) return 0 ;;
    *) return 1 ;;
  esac
}

validate_name()      { fm_machine_valid_name "$1" "$ROLE"; }
validate_role()      { fm_machine_valid_role "$1"; }
validate_transport() { fm_machine_valid_transport "$1"; }
validate_fleet()     { fm_machine_valid_fleet "$1"; }
validate_workspace() { fm_machine_valid_workspace "$1"; }
validate_workload()  { fm_machine_valid_workload "$1"; }
validate_robot()     { fm_machine_valid_robot "$1"; }

# --- Defaults ---------------------------------------------------------------

# Fill anything the caller did not pass: from the existing card first, so a
# repair run keeps the fields it was not asked to change, then from the host.
resolve_fields() {
  local existing=""
  fm_machine_exists && existing="$(fm_machine_file)"

  if [ -z "$ROLE" ]; then
    if [ -n "$existing" ]; then
      ROLE="$(fm_machine_get role)"
    elif [ "$(fm_detect_os)" = "macos" ]; then
      ROLE=mac
    else
      ROLE="$(fm_detect_role)"
    fi
  fi
  validate_role "$ROLE" || return 1

  if [ -z "$NAME" ]; then
    if [ -n "$existing" ]; then
      NAME="$(fm_machine_get name)"
    else
      # 01 is a guess, and the only field here that a second machine must
      # override. Two rigs flashed from the same command would otherwise both
      # answer to fm-rec-01, which is exactly the collision the old singular
      # fm-jetson caused.
      NAME="fm-$(fm_machine_abbrev "$ROLE")-01"
      fm_warn "no --name given — defaulting to $NAME; pass --name on the second machine of a role"
    fi
  fi
  validate_name "$NAME" || return 1

  [ -n "$FLEET" ]     || FLEET="$([ -n "$existing" ] && fm_machine_get fleet || printf '%s' "$FM_MACHINE_FLEET_DEFAULT")"
  [ -n "$TRANSPORT" ] || TRANSPORT="$([ -n "$existing" ] && fm_machine_get transport || printf '%s' "${FM_MACHINE_TRANSPORTS[0]}")"
  [ -n "$WORKSPACE" ] || WORKSPACE="$([ -n "$existing" ] && fm_machine_get workspace || printf '%s' "$FM_MACHINE_WORKSPACE_DEFAULT")"

  # The one field a repair run does not simply carry forward. Every other value
  # on an old card is still a fact about the machine; a workspace inside a home
  # directory is the shape this repo has since stopped writing, and leaving it
  # would mean a host converges on everything except the thing that keeps the
  # team out of its checkouts. An explicit --workspace still wins, including one
  # that puts it back.
  #
  # Not on a mac, where a workspace in the home is the right answer and the only
  # one available. /opt/fm is made by 12-workspace.sh, which runs on Linux and on
  # no mac; the mac role runs no steps at all. Converging there would point every
  # tool at a directory nothing creates, on the one kind of host that has a
  # single account and so never had the problem this converge exists to fix.
  if [ "$ROLE" != mac ] && [ "$WORKSPACE_EXPLICIT" = 0 ] && workspace_in_home "$WORKSPACE"; then
    fm_warn "workspace $WORKSPACE is inside a home directory — moving the card to $FM_MACHINE_WORKSPACE_DEFAULT"
    WORKSPACE="$FM_MACHINE_WORKSPACE_DEFAULT"
  fi

  # A value the caller passed wins, normalised so that `none` clears the field;
  # otherwise an existing card's workload carries forward like every other field
  # a repair run was not asked to change.
  if [ -n "$WORKLOAD" ]; then
    WORKLOAD="$(fm_machine_workload_value "$WORKLOAD")"
  elif [ -n "$existing" ]; then
    WORKLOAD="$(fm_machine_get_opt workload)"
  fi

  # A value the caller passed wins; otherwise an existing card's carries forward
  # like every other field a repair run was not asked to change. Not carried when
  # the role moved off `robot`: the card would then claim hardware this machine
  # is no longer said to be, and the fleet would pick an adapter for it.
  if [ -z "$ROBOT" ] && [ -n "$existing" ] && [ "$ROLE" = robot ]; then
    ROBOT="$(fm_machine_robot)"
  fi

  # A robot with no kind is a card the fleet cannot act on: fm-comms cannot pick
  # a bridge profile from it and the robot agent cannot pick an adapter. A kind
  # on anything else is a claim about hardware the machine does not have, and it
  # would select that profile anyway.
  if [ "$ROLE" = robot ] && [ -z "$ROBOT" ]; then
    fm_err "role 'robot' needs --robot <${FM_MACHINE_ROBOTS[*]}>"
    return 1
  fi
  if [ "$ROLE" != robot ] && [ -n "$ROBOT" ]; then
    fm_err "--robot is for the 'robot' role, not '$ROLE'"
    return 1
  fi

  validate_fleet "$FLEET" || return 1
  validate_transport "$TRANSPORT" || return 1
  validate_workload "$WORKLOAD" || return 1
  validate_robot "$ROBOT" || return 1
  validate_workspace "$WORKSPACE" || return 1
}

card_json() {
  jq -n \
    --argjson schema_version "$FM_MACHINE_SCHEMA_VERSION" \
    --arg name "$NAME" \
    --arg role "$ROLE" \
    --arg fleet "$FLEET" \
    --arg transport "$TRANSPORT" \
    --arg workload "$WORKLOAD" \
    --arg robot "$ROBOT" \
    --arg workspace "$WORKSPACE" \
    '{schema_version: $schema_version, name: $name, role: $role, fleet: $fleet, transport: $transport}
     + (if $workload == "" then {} else {workload: $workload} end)
     + (if $robot == "" then {} else {robot: $robot} end)
     + {workspace: $workspace}'
}

# --- Verbs ------------------------------------------------------------------

# card_sudo CMD… — run CMD as root only when the card lives outside $HOME.
#
# /etc/fm needs root; the macOS path under ~/.config does not, and writing it as
# root would leave the owner's own config file owned by root — every later
# repair would then need a password to fix a file that was never the system's.
# FM_MACHINE_FILE never escalates. It exists for tests and container rehearsal,
# which write where the caller can already write; honouring it with sudo would
# turn a debugging override into a way to spend someone's sudo on a path of the
# environment's choosing.
card_sudo() {
  [ -n "${FM_MACHINE_FILE:-}" ] && { "$@"; return; }
  case "$(fm_machine_file)" in
    "$HOME"/*) "$@" ;;
    *) if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi ;;
  esac
}

# The hostname is not a copy of the name, it *is* the name — mDNS discovery, the
# tailnet, and the sync timer's source field all read it. Aligning it here keeps
# a renamed card from leaving the host answering to its old identity.
align_hostname() {
  local current
  [ "$ROLE" = "mac" ] && { fm_skip "hostname alignment (mac role)"; return 0; }
  fm_has_cmd hostnamectl || { fm_warn "no hostnamectl — set the hostname to $NAME by hand"; return 0; }
  current="$(hostnamectl --static 2>/dev/null || true)"
  if [ "$current" = "$NAME" ]; then
    fm_ok "hostname is $NAME"
    return 0
  fi
  sudo hostnamectl set-hostname "$NAME"
  # /etc/hosts keeps its own copy of the old name; sudo resolves it on every
  # invocation and stalls for seconds when it no longer resolves.
  #
  # Only rewritten when there is an old name to match. An empty `current` would
  # make the expression `s/\b\b/name/g`, which matches at every word boundary in
  # the file and turns /etc/hosts into noise on the one machine — a host with no
  # static hostname — least able to be reached afterwards to fix it.
  if [ -n "$current" ]; then
    sudo sed -i "s/\b${current}\b/$NAME/g" /etc/hosts 2>/dev/null || true
  fi
  fm_ok "hostname $current → $NAME"
}

do_init() {
  local file dir tmp
  fm_require_cmd jq || return "$EX_PRECONDITION"
  resolve_fields || return "$EX_USAGE"
  file="$(fm_machine_file)"
  dir="$(dirname "$file")"

  if [ "$DRY_RUN" = 1 ]; then
    fm_log "would write $file"
    card_json
    return 0
  fi

  # Written through a temporary file in the target's own directory and moved
  # into place, so a reader never sees a half-written card — services read this
  # at boot, concurrently with a repair run.
  card_sudo mkdir -p "$dir"
  tmp="$(card_sudo mktemp "$dir/.machine.XXXXXX")"
  card_json | card_sudo tee "$tmp" >/dev/null
  card_sudo chmod 0644 "$tmp"
  card_sudo mv "$tmp" "$file"
  fm_ok "wrote $file"
  fm_info "name       $NAME"
  fm_info "role       $ROLE"
  fm_info "fleet      $FLEET"
  fm_info "transport  $TRANSPORT"
  fm_info "workload   ${WORKLOAD:-none}"
  fm_info "robot      ${ROBOT:-none}"
  fm_info "workspace  $WORKSPACE"
  fm_info "namespace  $(fm_machine_namespace "$NAME")  (derived, never typed)"
  # The card is read once, at service start. Nothing here can reach into a
  # running fm-zenoh-bridge and tell it the workload changed, and a bridge that
  # kept its old profile filters with the old allow-list while every file on the
  # machine says otherwise (fm-comms#20).
  fm_info "transport services read the card at start — restart fm-zenoh-bridge"

  align_hostname
}

do_show() {
  local file
  file="$(fm_machine_file)"
  [ -f "$file" ] || { fm_err "no machine identity card at $file — run 'fm machine init'"; return "$EX_PRECONDITION"; }
  if [ "$AS_JSON" = 1 ]; then
    fm_require_cmd jq || return "$EX_PRECONDITION"
    jq --arg ns "$(fm_machine_namespace)" '. + {namespace: $ns}' "$file"
    return 0
  fi
  fm_log "machine"
  fm_info "card       $file"
  fm_info "name       $(fm_machine_get name)"
  fm_info "role       $(fm_machine_get role)"
  fm_info "fleet      $(fm_machine_get fleet)"
  fm_info "transport  $(fm_machine_get transport)"
  fm_info "workload   $(fm_machine_workload || true)"
  fm_info "robot      $(fm_machine_robot || true)"
  fm_info "workspace  $(fm_machine_get workspace)"
  fm_info "namespace  $(fm_machine_namespace)"
}

# doctor reports; it never repairs. `machine init` is the repair, and keeping the
# two apart means a check can run on a machine nobody wants changed today.
do_doctor() {
  local file version problems=0 value host
  fm_require_cmd jq || return "$EX_PRECONDITION"
  file="$(fm_machine_file)"

  fm_log "machine doctor"

  if [ ! -f "$file" ]; then
    fm_err "no card at $file"
    fm_info "a provisioned host needs one: fm machine init --name fm-<abbrev>-<nn>"
    fm_info "a laptop running the desktop app in client mode does not"
    return "$EX_PRECONDITION"
  fi
  if ! jq -e . "$file" >/dev/null 2>&1; then
    fm_err "$file is not valid JSON"
    return "$EX_PRECONDITION"
  fi

  version="$(jq -r '.schema_version // empty' "$file")"
  if [ "$version" != "$FM_MACHINE_SCHEMA_VERSION" ]; then
    fm_err "schema_version $version — this fm-setup knows $FM_MACHINE_SCHEMA_VERSION"
    fm_info "a reader that does not know the version must refuse the card, not guess"
    problems=$((problems + 1))
  else
    fm_ok "schema_version $version"
  fi

  # Each field is read, then checked with the same validator init writes
  # through, so a hand-edited card is judged by exactly one set of rules.
  ROLE="$(jq -r '.role // empty' "$file")"
  if validate_role "$ROLE" 2>/dev/null; then fm_ok "role $ROLE"; else fm_err "invalid role: '$ROLE'"; problems=$((problems + 1)); fi

  value="$(jq -r '.name // empty' "$file")"
  if validate_name "$value" 2>/dev/null; then fm_ok "name $value"; else fm_err "invalid name for role '$ROLE': '$value'"; problems=$((problems + 1)); fi

  # The hostname is the name in practice. A card that disagrees with the host is
  # the drift that makes a rig unreachable at the name everyone was told.
  if [ "$ROLE" != "mac" ] && fm_has_cmd hostnamectl; then
    host="$(hostnamectl --static 2>/dev/null || true)"
    if [ "$host" = "$value" ]; then
      fm_ok "hostname matches the card"
    else
      fm_err "hostname is '$host', card says '$value' — run 'fm machine init' to re-align"
      problems=$((problems + 1))
    fi
  fi

  value="$(jq -r '.fleet // empty' "$file")"
  if validate_fleet "$value" 2>/dev/null; then fm_ok "fleet $value"; else fm_err "invalid fleet: '$value'"; problems=$((problems + 1)); fi

  value="$(jq -r '.transport // empty' "$file")"
  if validate_transport "$value" 2>/dev/null; then fm_ok "transport $value"; else fm_err "invalid transport: '$value'"; problems=$((problems + 1)); fi

  # The one optional field, so absence is reported rather than counted. A rig
  # with no workload is a rig whose bridge profile nothing can derive, which is
  # worth seeing on a recorder and is entirely normal on a workstation.
  value="$(jq -r '.workload // empty' "$file")"
  if ! validate_workload "$value" 2>/dev/null; then
    fm_err "invalid workload: '$value'"
    problems=$((problems + 1))
  elif [ -n "$value" ]; then
    fm_ok "workload $value"
  else
    fm_info "workload   none — this machine hosts no bridge profile"
  fi

  # The second optional field, and the one whose absence is only a problem on a
  # robot. Reported the same way workload is, then held to the role.
  value="$(jq -r '.robot // empty' "$file")"
  if ! validate_robot "$value" 2>/dev/null; then
    fm_err "invalid robot: '$value'"
    problems=$((problems + 1))
  elif [ -n "$value" ] && [ "$ROLE" != robot ]; then
    fm_err "robot '$value' on role '$ROLE' — only a robot card carries one"
    problems=$((problems + 1))
  elif [ -z "$value" ] && [ "$ROLE" = robot ]; then
    fm_err "role robot with no robot — nothing can tell which robot this is"
    problems=$((problems + 1))
  elif [ -n "$value" ]; then
    fm_ok "robot $value"
  fi

  value="$(jq -r '.workspace // empty' "$file")"
  if ! validate_workspace "$value" 2>/dev/null; then
    fm_err "invalid workspace: '$value'"
    problems=$((problems + 1))
  elif [ -d "$value" ]; then
    fm_ok "workspace $value"
  else
    # Not an error. The card is written before the checkouts land on a freshly
    # flashed rig, and a doctor that fails there would fail on every new machine.
    fm_warn "workspace $value does not exist yet"
  fi
  # Judged separately from whether it exists, because a workspace in a home
  # directory is wrong on a rig that has never booted and on one provisioned a
  # year ago alike. Right on a mac, though, which has one account and no step
  # that could make a workspace anywhere else — so doctor must not call that a
  # problem it can fix, having no fix to offer.
  if [ "$ROLE" != mac ] && workspace_in_home "$value"; then
    fm_err "workspace $value is inside a home directory — only that account can read it"
    fm_info "run 'fm machine init' to move the card to $FM_MACHINE_WORKSPACE_DEFAULT"
    problems=$((problems + 1))
  fi

  fm_info "namespace  $(fm_machine_namespace "$(jq -r '.name' "$file")" 2>/dev/null || echo '—')"

  # A flashed rig's first boot leaves this behind when a layer failed. Without
  # it a half-provisioned appliance looks healthy from every other check here.
  if [ -f "$FM_FIRST_BOOT_FAILED" ]; then
    fm_err "first boot failed at: $(cat "$FM_FIRST_BOOT_FAILED")"
    fm_info "see /var/log/fm-first-boot.log, then rerun: sudo /usr/local/sbin/fm-first-boot.sh"
    problems=$((problems + 1))
  fi

  if [ "$problems" -gt 0 ]; then
    fm_err "$problems problem(s)"
    return "$EX_PRECONDITION"
  fi
  fm_ok "card is consistent with this host"
}

do_reset() {
  local file
  file="$(fm_machine_file)"
  [ -f "$file" ] || { fm_skip "no card at $file"; return 0; }
  if [ "$DRY_RUN" = 1 ]; then
    fm_log "would remove $file"
    return 0
  fi
  # Removing the card leaves every consumer without a workspace, a namespace, or
  # a transport, so it is the inverse of init and asks before it acts.
  if [ "$ASSUME_YES" != 1 ]; then
    fm_confirm "remove $file? every consumer loses its workspace and namespace" || {
      fm_err "aborted"; return "$EX_PRECONDITION"
    }
  fi
  card_sudo rm -f "$file"
  fm_ok "removed $file"
}

# --- Front door -------------------------------------------------------------

main() {
  local verb="${1:-}"
  [ $# -gt 0 ] && shift

  while [ $# -gt 0 ]; do
    case "$1" in
      --name)      NAME="${2:?--name needs a value}"; shift 2 ;;
      --role)      ROLE="${2:?--role needs a value}"; shift 2 ;;
      --fleet)     FLEET="${2:?--fleet needs a value}"; shift 2 ;;
      --transport) TRANSPORT="${2:?--transport needs a value}"; shift 2 ;;
      --workload)  WORKLOAD="${2:?--workload needs a value (or 'none')}"; shift 2 ;;
      --robot)     ROBOT="${2:?--robot needs a value}"; shift 2 ;;
      --workspace) WORKSPACE="${2:?--workspace needs a value}"; WORKSPACE_EXPLICIT=1; shift 2 ;;
      --json)      AS_JSON=1; shift ;;
      --dry-run)   DRY_RUN=1; shift ;;
      -y|--yes)    ASSUME_YES=1; shift ;;
      -h|--help)   usage; return 0 ;;
      *) fm_err "unknown option: $1"; usage >&2; return "$EX_USAGE" ;;
    esac
  done

  case "$verb" in
    init)   do_init ;;
    show)   do_show ;;
    doctor) do_doctor ;;
    reset)  do_reset ;;
    ""|-h|--help) usage; [ -z "$verb" ] && return "$EX_USAGE" || return 0 ;;
    *) fm_err "unknown verb: $verb (use init|show|doctor|reset)"; usage >&2; return "$EX_USAGE" ;;
  esac
}

main "$@"
