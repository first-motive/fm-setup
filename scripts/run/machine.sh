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
WORKSPACE=""
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

validate_name()      { fm_machine_valid_name "$1" "$ROLE"; }
validate_role()      { fm_machine_valid_role "$1"; }
validate_transport() { fm_machine_valid_transport "$1"; }
validate_fleet()     { fm_machine_valid_fleet "$1"; }
validate_workspace() { fm_machine_valid_workspace "$1"; }
validate_workload()  { fm_machine_valid_workload "$1"; }

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

  # A value the caller passed wins, normalised so that `none` clears the field;
  # otherwise an existing card's workload carries forward like every other field
  # a repair run was not asked to change.
  if [ -n "$WORKLOAD" ]; then
    WORKLOAD="$(fm_machine_workload_value "$WORKLOAD")"
  elif [ -n "$existing" ]; then
    WORKLOAD="$(fm_machine_get_opt workload)"
  fi

  validate_fleet "$FLEET" || return 1
  validate_transport "$TRANSPORT" || return 1
  validate_workload "$WORKLOAD" || return 1
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
    --arg workspace "$WORKSPACE" \
    '{schema_version: $schema_version, name: $name, role: $role, fleet: $fleet, transport: $transport}
     + (if $workload == "" then {} else {workload: $workload} end)
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
  fm_info "workspace  $WORKSPACE"
  fm_info "namespace  $(fm_machine_namespace "$NAME")  (derived, never typed)"

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
      --workspace) WORKSPACE="${2:?--workspace needs a value}"; shift 2 ;;
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
