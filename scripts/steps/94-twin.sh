#!/usr/bin/env bash
#
# twin — serve fm-twin's live camera twin for this host's sim runs.
#
# fm-twin reads a sim run's cameras, depth and /tf off the fabric, masks the
# robot out of every frame, fuses the rest into one coloured cloud, and publishes
# it on <ns>/twin/points with its status on fm/twin/<ns>/status. It takes its
# config from fm/twin/<ns>/config while it runs. It is pure CPU and needs the
# router, nothing else. This step puts it on the host:
#
#   the code         fm-twin at the commit the manifest pins, in a root-owned
#                    tree with a root-built venv (scripts/internal/service-lib.sh)
#   the descriptions the URDF and meshes of every robot in FM_TWIN_ROBOTS (the
#                    OpenArm and the Axol), copied out of the pinned controllers
#                    image
#   the service      fm-twin.service, run by systemd as its own account:
#                    fm-twin run --source sim:<this host> --robot <name>=<urdf> ...
#   the robot twin   fm-twin-robot@.service, the same account and hardening:
#                    fm-twin run --source robot:<instance> --profile axol --urdf <axol urdf>
#                    installed, never enabled; the host agent starts an instance
#
# The twin serves the robot of the host's active sim run. When a run of another
# robot holds, it exits 75 and systemd starts it again on that robot.
#
# The account is in no group — not docker, not fm — and the unit holds no
# capability. What it may do is what any peer on the router may.
#
# fm-twin is private, and root holds no GitHub credential. The workspace's owner
# does (the fm-policy step clones as the same account), so that account fetches
# the pinned commit into a temp repository of its own and writes it out as a git
# bundle. Root never runs git in the owner's repository, whose config could name
# a command for root to run: it copies the bundle into a root-owned directory,
# verifies it, fetches it into its own bare repository under FM_TWIN_ROOT with
# every object checked, and refuses anything that is not the pinned SHA. The
# workspace's fm-twin checkout, if there is one, is never read.
#
# The descriptions are private too. A sim host only has them inside
# FM_SIM_CONTROLLERS_IMAGE, which the sim step pulls with FM_SIM_CONTROLLERS=1,
# so the twin masks exactly the robots the sim runs. This step never pulls it.
# `docker cp` streams each description as a tar into a root-owned file, every
# entry is listed and refused unless it is a plain file or directory under that
# description's own directory, and only then does root extract it.
#
# The router endpoint is FM_ROUTER_ENDPOINT from /etc/fm-comms.env, the unit's
# EnvironmentFile, which fm-twin reads when no --router is given. The host is the
# card's name. Neither is typed here.
#
# install exits 1 on a failure: a malformed pin, digest or robot entry, a fetch
# that does not match, a refused tree or archive, any privileged command that
# fails. It exits 0 when it stops at a gate a person clears later — no commit
# pinned, no GitHub credential, the controllers image not pulled,
# /etc/fm-comms.env not there yet — and says which.
#
#   bash scripts/steps/94-twin.sh install --dry-run    print the plan, change nothing
#
# Test hooks, for scripts/dev/test-twin.sh only and refused without
# FM_TWIN_TEST=1: FM_TWIN_TEST_ROOT prefixes every path the step writes (and
# must sit under the temp directory), FM_TWIN_TEST_SOURCE replaces the GitHub
# URL and FM_TWIN_TEST_UV_SHA256 the uv checksum. Both are refused unless a
# valid FM_TWIN_TEST_ROOT is set too. The unit's text never carries any of them.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$_here/../.." && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$FM_ROOT/lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$FM_ROOT/scripts/manifest.sh"
# shellcheck source=../internal/service-lib.sh disable=SC1091
. "$FM_ROOT/scripts/internal/service-lib.sh"

fm_require_linux

# Literal, because the drift audit reads this line with sed. FM_TWIN_UNIT.
# shellcheck disable=SC2034
FM_UNITS=(fm-twin.service)

# A test hook's value, or a refusal outside a test run.
test_knob() { svc_test_knob FM_TWIN_TEST "$1"; }

R="$(test_knob FM_TWIN_TEST_ROOT)" || exit 1
if [ -n "$R" ]; then svc_test_root_ok FM_TWIN_TEST_ROOT "$R" || exit 1; fi
SOURCE_URL="$(test_knob FM_TWIN_TEST_SOURCE)" || exit 1
TEST_UV_SHA="$(test_knob FM_TWIN_TEST_UV_SHA256)" || exit 1
if { [ -n "$SOURCE_URL" ] || [ -n "$TEST_UV_SHA" ]; } && [ -z "$R" ]; then
  fm_err "FM_TWIN_TEST_SOURCE and FM_TWIN_TEST_UV_SHA256 need FM_TWIN_TEST_ROOT — refusing"
  exit 1
fi
SOURCE_URL="${SOURCE_URL:-https://github.com/$FM_TWIN_REPO.git}"

TWIN_COMMIT="${FM_TWIN_COMMIT:-$FM_TWIN_COMMIT_DEFAULT}"
# The same pin, and the same override, as the sim step's controllers image.
IMAGE_DIGEST="${FM_SIM_CONTROLLERS_IMAGE_DIGEST:-$FM_SIM_CONTROLLERS_IMAGE_DIGEST_DEFAULT}"

COMMS_ENV=/etc/fm-comms.env
UNIT_PATH="/etc/systemd/system/$FM_TWIN_UNIT"
ROBOT_UNIT_PATH="/etc/systemd/system/$FM_TWIN_ROBOT_UNIT"
# Every running instance of the robot template, for a restart or a stop.
ROBOT_INSTANCES="${FM_TWIN_ROBOT_UNIT%@.service}@*.service"
SRC_GIT="$FM_TWIN_ROOT/src.git"
PROJECT_DIR="$FM_TWIN_ROOT/project"
VENV_DIR="$FM_TWIN_ROOT/venv"
ENTRYPOINT="$VENV_DIR/bin/fm-twin"
DESCRIPTION_ROOT="$FM_TWIN_ROOT/description"
# Written last, after the venv is built and after the description is copied.
COMMIT_MARKER="$FM_TWIN_ROOT/.fm-commit"
DESCRIPTION_MARKER="$DESCRIPTION_ROOT/.fm-image"
# The largest bundle root takes from the owner. fm-twin's whole history is a
# few megabytes; a bundle far past that is not the repository.
BUNDLE_MAX_BYTES=$((256 * 1024 * 1024))
# What the venv is built from. Tests, docs and benches stay behind.
SOURCE_FILES=(pyproject.toml uv.lock README.md src)

# git with nothing inherited: no user or system config, no replace objects, no
# prompt, and a fixed PATH. Root runs it against its own repository only.
GIT_ENV=(env -i PATH=/usr/bin:/bin HOME=/nonexistent GIT_NO_REPLACE_OBJECTS=1
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0)
src_git()  { sudo "${GIT_ENV[@]}" git -c "safe.directory=$R$SRC_GIT" --git-dir="$R$SRC_GIT" "$@"; }
# The repository is root-owned and world-readable, so a report reads it plainly.
read_src_git() { "${GIT_ENV[@]}" git -c "safe.directory=$R$SRC_GIT" --git-dir="$R$SRC_GIT" "$@"; }

# --- Pins ---------------------------------------------------------------------

# 0 when a commit is pinned and shaped like a full SHA; 1 when none is; 2 when
# one is malformed.
commit_pinned() {
  [ -n "$TWIN_COMMIT" ] || return 1
  if ! printf '%s' "$TWIN_COMMIT" | grep -Eq '^[0-9a-f]{40}$'; then
    fm_err "FM_TWIN_COMMIT is malformed: '$TWIN_COMMIT' (want a full 40-character SHA)"
    return 2
  fi
}

# The controllers image by digest. No digest is a refusal, not a moving tag: the
# descriptions must be the ones the sim runs.
image_ref() {
  if [[ "$IMAGE_DIGEST" == *$'\n'* ]] || ! printf '%s' "$IMAGE_DIGEST" | grep -Eq '^sha256:[0-9a-f]{64}$'; then
    fm_err "FM_SIM_CONTROLLERS_IMAGE_DIGEST is malformed or unset: '$IMAGE_DIGEST' (want sha256:<64 hex>)"
    return 1
  fi
  printf '%s@%s\n' "${FM_SIM_CONTROLLERS_IMAGE%:*}" "$IMAGE_DIGEST"
}

# The card's name, the host fm-twin serves. Checked as the card is, and as every
# word of a unit's command line is.
host_name() {
  local name
  name="$(fm_machine_get name)" || return 1
  fm_machine_valid_name "$name" || return 1
  svc_safe_word "$name" || return 1
  printf '%s\n' "$name"
}

# robot_list — every FM_TWIN_ROBOTS entry, validated, one per line as
# "robot|dir|path|top|urdf", where top is the last component of path: the top
# directory `docker cp` streams. Callers read a line with `IFS='|' read -r`.
# Refuses the whole list if any entry could name a path outside its own
# directory: dir and top must each be one safe path component, path absolute,
# and urdf relative with no '..'.
robot_list() {
  local entry robot dir path urdf top
  local component='^[A-Za-z0-9_][A-Za-z0-9_.-]*$'
  for entry in "${FM_TWIN_ROBOTS[@]}"; do
    IFS='|' read -r robot dir path urdf <<<"$entry"
    top="${path##*/}"
    if [[ "$entry" == *$'\n'* ]] || ! [[ "$robot" =~ ^[a-z][a-z0-9_-]*$ ]] \
       || ! [[ "$dir" =~ $component ]] || ! [[ "$top" =~ $component ]] \
       || [[ "$path" != /* ]] || [ -z "$urdf" ] || [[ "$urdf" == /* ]] \
       || [[ "$urdf" == *'|'* ]] || [[ "/$urdf/" == */../* ]]; then
      fm_err "FM_TWIN_ROBOTS entry is malformed: '$entry' (want robot|dir|/path/to/dir|relative urdf)"
      return 1
    fi
    printf '%s|%s|%s|%s|%s\n' "$robot" "$dir" "$path" "$top" "$urdf"
  done
}

# robot_args — the unit's --robot words, one pair per robot, each checked as
# every word of a unit's command line is.
robot_args() {
  local list robot dir path top urdf words=()
  list="$(robot_list)" || return 1
  while IFS='|' read -r robot dir path top urdf; do
    svc_safe_word "$robot=$DESCRIPTION_ROOT/$dir/$urdf" || return 1
    words+=(--robot "$robot=$DESCRIPTION_ROOT/$dir/$urdf")
  done <<<"$list"
  printf '%s\n' "${words[*]}"
}

# render HOST — the unit for this host.
render() {
  local args
  args="$(robot_args)" || return 1
  cat <<UNIT
# fm-twin — the live camera twin for this host's sim runs, over Zenoh.
#
# Rendered by fm-setup's twin step (scripts/steps/94-twin.sh) for fm-twin
# $TWIN_COMMIT.
# Re-run the step rather than editing this file. Its own account, in no group:
# it needs the router and nothing on the host.
[Unit]
Description=fm-twin: the live camera twin for this host's sim runs
After=network-online.target $FM_COMMS_BRIDGE_UNIT $FM_COMMS_SIM_BRIDGE_UNIT
Wants=network-online.target

[Service]
Type=simple
User=$FM_TWIN_USER
Group=$FM_TWIN_USER
# The router endpoint (FM_ROUTER_ENDPOINT), as every other First Motive unit reads it.
EnvironmentFile=$COMMS_ENV
ExecStart=$ENTRYPOINT run --source sim:$1 $args
Restart=on-failure
RestartSec=5
# The twin exits 75 to be started again on the robot of another run. fm-twin
# exits so only once a new run of another robot has held (SWITCH_AFTER_S in
# fm_twin.sim_robot), so the unit restarts once per such run.
RestartForceExitStatus=75
# The fused cloud's layers are bounded (about 44 MB static, 250,000 points out);
# the rest is four cameras' frames in flight and OpenCV's and zenoh's threads.
MemoryMax=8G
TasksMax=512
NoNewPrivileges=yes
CapabilityBoundingSet=
RestrictSUIDSGID=yes
# The router over TCP; nothing else.
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
RestrictNamespaces=yes
LockPersonality=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
UNIT
}

# robot_urdf — the installed URDF of FM_TWIN_ROBOT_PROFILE's FM_TWIN_ROBOTS
# entry, the robot the robot twin serves. 2, saying nothing, when the list holds
# no such entry: the sim twin needs no robot twin, so callers skip it.
robot_urdf() {
  local list robot dir path top urdf
  list="$(robot_list)" || return 1
  while IFS='|' read -r robot dir path top urdf; do
    if [ "$robot" = "$FM_TWIN_ROBOT_PROFILE" ]; then
      svc_safe_word "$DESCRIPTION_ROOT/$dir/$urdf" || return 1
      printf '%s\n' "$DESCRIPTION_ROOT/$dir/$urdf"
      return 0
    fi
  done <<<"$list"
  return 2
}

# The message for robot_urdf's 2.
no_robot_entry() {
  printf 'FM_TWIN_ROBOTS has no %s entry (FM_TWIN_ROBOT_PROFILE) — no robot twin\n' "$FM_TWIN_ROBOT_PROFILE"
}

# robot_twins — the robot twin instances systemd has loaded, one per line. A
# stop or restart names them, never a glob, so none loaded means nothing to ask.
robot_twins() {
  systemctl list-units --plain --no-legend --all "$ROBOT_INSTANCES" 2>/dev/null | awk '$1 ~ /\.service$/ {print $1}'
}

# render_robot — the robot twin's template unit. Its instance is the robot's
# fleet name, which the host agent checks before it names an instance.
render_robot() {
  local urdf
  urdf="$(robot_urdf)" || return $?
  svc_safe_word "$FM_TWIN_ROBOT_PROFILE" || return 1
  cat <<UNIT
# fm-twin-robot@ — the live camera twin for one robot, over Zenoh. The instance
# is the robot's fleet name: fm-twin-robot@fm-rob-02.service serves fm-rob-02.
#
# Rendered by fm-setup's twin step (scripts/steps/94-twin.sh) for fm-twin
# $TWIN_COMMIT.
# Re-run the step rather than editing this file. Never enabled: the host agent
# starts and stops an instance when fm-desktop asks.
[Unit]
Description=fm-twin: the live camera twin for robot %i
After=network-online.target $FM_COMMS_BRIDGE_UNIT
Wants=network-online.target

[Service]
Type=simple
User=$FM_TWIN_USER
Group=$FM_TWIN_USER
# The router endpoint (FM_ROUTER_ENDPOINT), as every other First Motive unit reads it.
EnvironmentFile=$COMMS_ENV
ExecStart=$ENTRYPOINT run --source "robot:%i" --profile $FM_TWIN_ROBOT_PROFILE --urdf $urdf
Restart=on-failure
RestartSec=5
# Bounded as the sim twin is; the Axol's head adds a stereo match per frame.
MemoryMax=8G
TasksMax=512
NoNewPrivileges=yes
CapabilityBoundingSet=
RestrictSUIDSGID=yes
# The router over TCP; nothing else.
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
RestrictNamespaces=yes
LockPersonality=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
UNIT
}

same_file() { [ -f "$1" ] && [ "$(cat "$1")" = "$2" ]; }
venv_current() { [ "$(cat "$R$COMMIT_MARKER" 2>/dev/null)" = "$TWIN_COMMIT" ] && [ -x "$R$ENTRYPOINT" ]; }
have_commit() { read_src_git rev-parse --verify --quiet "refs/fm/$TWIN_COMMIT^{commit}" >/dev/null 2>&1; }
in_any_group() { [ "$(id -nG "$FM_TWIN_USER" 2>/dev/null)" != "$FM_TWIN_USER" ]; }
image_pulled() { fm_has_docker && docker image inspect "$1" >/dev/null 2>&1; }
# robot_current REF DIR URDF — 0 when the descriptions came from REF and this
# robot's URDF, DIR/URDF under the description root, is in place.
robot_current() {
  [ "$(cat "$R$DESCRIPTION_MARKER" 2>/dev/null)" = "$1" ] && [ -f "$R$DESCRIPTION_ROOT/$2/$3" ]
}

# description_current REF — 0 when every robot's description is current.
description_current() {
  local list robot dir path top urdf
  list="$(robot_list 2>/dev/null)" || return 1
  while IFS='|' read -r robot dir path top urdf; do
    robot_current "$1" "$dir" "$urdf" || return 1
  done <<<"$list"
}

# --- Check --------------------------------------------------------------------

do_check() {
  local rc=0 ref name unit list robot dir path top urdf
  commit_pinned || rc=$?
  case "$rc" in
    0) fm_ok "fm-twin pinned at $TWIN_COMMIT" ;;
    1) fm_warn "no fm-twin commit pinned (FM_TWIN_COMMIT_DEFAULT) — no twin can be installed" ;;
  esac
  if [ "$rc" = 0 ] && have_commit; then fm_ok "$SRC_GIT holds the pinned commit"; else fm_warn "$SRC_GIT does not hold the pinned commit"; fi
  if [ "$rc" = 0 ] && venv_current; then
    fm_ok "$VENV_DIR is fm-twin at the pinned commit"
  else
    fm_warn "$VENV_DIR is not fm-twin at the pinned commit"
  fi
  if svc_uv_current "$R" "$FM_TWIN_ROOT" "$(svc_uv_sha "$TEST_UV_SHA" 2>/dev/null)"; then
    fm_ok "$FM_TWIN_ROOT/bin/uv is the pinned uv $FM_UV_VERSION"
  else
    fm_warn "$FM_TWIN_ROOT/bin/uv is not the pinned uv $FM_UV_VERSION"
  fi

  if getent passwd "$FM_TWIN_USER" >/dev/null 2>&1; then
    fm_ok "account $FM_TWIN_USER present"
    if in_any_group; then
      fm_warn "$FM_TWIN_USER is in groups beyond its own: $(id -nG "$FM_TWIN_USER") — it should hold none"
    fi
  else
    fm_warn "account $FM_TWIN_USER missing"
  fi

  # image_ref names what it refuses, so its message is left on stderr.
  # robot_list names what it refuses too.
  if ref="$(image_ref)" && list="$(robot_list)"; then
    while IFS='|' read -r robot dir path top urdf; do
      if robot_current "$ref" "$dir" "$urdf"; then
        fm_ok "$robot: $DESCRIPTION_ROOT/$dir/$urdf is the description in $ref"
      else
        fm_warn "$robot: $DESCRIPTION_ROOT/$dir/$urdf is not the description in $ref"
      fi
    done <<<"$list"
    if ! description_current "$ref" && ! image_pulled "$ref"; then
      fm_info "$ref is not pulled — pull it with: FM_SIM_CONTROLLERS=1 ./install.sh --${FM_ROLE:-workstation} --only sim"
    fi
  fi

  if [ "$rc" = 0 ] && name="$(host_name 2>/dev/null)" && unit="$(render "$name")"; then
    if same_file "$R$UNIT_PATH" "$unit"; then
      fm_ok "$FM_TWIN_UNIT installed and current — serves sim:$name"
    else
      fm_warn "$FM_TWIN_UNIT missing or out of date — re-run: ./install.sh --${FM_ROLE:-workstation} --only twin"
    fi
  fi
  if [ "$rc" = 0 ]; then
    local robot_rc=0
    unit="$(render_robot 2>/dev/null)" || robot_rc=$?
    if [ "$robot_rc" = 2 ]; then
      fm_warn "$(no_robot_entry)"
    elif [ "$robot_rc" = 0 ] && same_file "$R$ROBOT_UNIT_PATH" "$unit"; then
      fm_ok "$FM_TWIN_ROBOT_UNIT installed and current — serves robot:<instance> as $FM_TWIN_ROBOT_PROFILE"
    elif [ "$robot_rc" = 0 ]; then
      fm_warn "$FM_TWIN_ROBOT_UNIT missing or out of date — re-run: ./install.sh --${FM_ROLE:-workstation} --only twin"
    fi
  fi
  if fm_has_cmd systemctl && systemctl is-active --quiet "$FM_TWIN_UNIT" 2>/dev/null; then
    fm_ok "$FM_TWIN_UNIT active"
  else
    fm_warn "$FM_TWIN_UNIT not active"
  fi
  return 0
}

# --- Install ------------------------------------------------------------------

dry_run_plan() {
  local ref name unit robot_unit="" rc=0 list robot dir path top urdf
  ref="$(image_ref)" || return 1
  name="$(host_name)" || return 1
  list="$(robot_list)" || return 1
  unit="$(render "$name")" || return 1
  robot_unit="$(render_robot)" || rc=$?
  case "$rc" in 0 | 2) ;; *) return 1 ;; esac
  rc=0
  commit_pinned || rc=$?
  [ "$rc" = 2 ] && return 1
  fm_log "dry run — nothing on this host changes"
  if [ "$rc" = 1 ]; then
    fm_info "no fm-twin commit pinned (FM_TWIN_COMMIT_DEFAULT) — would install no twin"
    return 0
  fi
  fm_info "would fetch  $TWIN_COMMIT from $SOURCE_URL (as $(fm_workspace_owner)) into a bundle"
  fm_info "would fetch  that bundle into $SRC_GIT (as root, verified, every object checked)"
  fm_info "would copy   ${SOURCE_FILES[*]} at that commit to $PROJECT_DIR (root:root, 755/644)"
  fm_info "would fetch  uv $FM_UV_VERSION to $FM_TWIN_ROOT/bin/uv, checked against sha256 $(svc_uv_sha "$TEST_UV_SHA")"
  fm_info "would build  $VENV_DIR as root (uv sync --frozen --no-editable)"
  while IFS='|' read -r robot dir path top urdf; do
    fm_info "would copy   $robot's $path out of $ref"
    fm_info "             to $DESCRIPTION_ROOT/$dir (root:root, 755/644)"
  done <<<"$list"
  fm_info "would create system account $FM_TWIN_USER (no home, no login, no groups)"
  fm_info "would write  $UNIT_PATH:"
  printf '%s\n' "$unit" | sed 's/^/        /'
  if [ -n "$robot_unit" ]; then
    fm_info "would write  $ROBOT_UNIT_PATH (not enabled):"
    printf '%s\n' "$robot_unit" | sed 's/^/        /'
  else
    fm_info "would write  no $ROBOT_UNIT_PATH: $(no_robot_entry)"
  fi
  fm_info "would enable and start $FM_TWIN_UNIT once $COMMS_ENV exists"
}

# owner_bundle DIR — as the workspace's owner, fetch the pinned commit and write
# it to DIR/pin.bundle. The owner's own git, credential helper and all: that is
# the credential. Its whole history, because a bundle of a shallow commit names
# parents root does not have. Nothing it writes is trusted until root checks it.
owner_bundle() {
  local dir="$1"
  fm_as_workspace_owner git init --quiet --bare "$dir/repo" \
    && fm_as_workspace_owner env GIT_TERMINAL_PROMPT=0 git --git-dir="$dir/repo" \
         fetch --quiet --no-tags "$SOURCE_URL" "$TWIN_COMMIT:refs/fm/pin" \
    && fm_as_workspace_owner git --git-dir="$dir/repo" bundle create --quiet "$dir/pin.bundle" refs/fm/pin
}

# fetch_source — the pinned commit in root's bare repository. 0 when it is
# there, 2 when the workspace's owner could not fetch it (a credential a person
# adds later), 1 on any other failure.
fetch_source() {
  local owner spool stage bundle got rc=0
  if have_commit; then
    fm_ok "$SRC_GIT holds $TWIN_COMMIT"
    return 0
  fi
  svc_must "creating $FM_TWIN_ROOT" sudo install -d -o root -g root -m 0755 "$R$FM_TWIN_ROOT" || return 1
  if [ ! -f "$R$SRC_GIT/HEAD" ]; then
    svc_must "creating $SRC_GIT" sudo "${GIT_ENV[@]}" git init --quiet --bare "$R$SRC_GIT" || return 1
  fi

  owner="$(fm_workspace_owner)"
  spool="$(fm_as_workspace_owner mktemp -d)" || { fm_err "creating a spool directory as $owner failed"; return 1; }
  fm_log "fetching fm-twin $TWIN_COMMIT (as $owner)"
  if ! owner_bundle "$spool"; then
    fm_as_workspace_owner rm -rf "$spool"
    fm_warn "could not fetch $FM_TWIN_REPO as $owner — fm-twin is private"
    fm_info "authenticate as $owner (gh auth login), then re-run: ./install.sh --${FM_ROLE:-workstation} --only twin"
    return 2
  fi
  # The bundle is data to root, judged only once root holds its own copy, which
  # the owner cannot change or swap. `cp -RP` copies a link as a link and a
  # FIFO as a FIFO, never following or reading either, so the check on the copy
  # refuses whatever the owner's path was.
  stage="$(sudo mktemp -d "$R$FM_TWIN_ROOT/.bundle.XXXXXX")" || { fm_as_workspace_owner rm -rf "$spool"; fm_err "creating a staging directory failed"; return 1; }
  bundle="$stage/pin.bundle"
  svc_must "copying the bundle" sudo cp -RP "$spool/pin.bundle" "$bundle" || rc=1
  if [ "$rc" = 0 ]; then
    if sudo test -L "$bundle" || ! sudo test -f "$bundle"; then
      fm_err "the owner's pin.bundle is not a plain file — refusing it"
      rc=1
    elif [ "$(sudo stat -c %s "$bundle")" -gt "$BUNDLE_MAX_BYTES" ]; then
      fm_err "the owner's pin.bundle is over $BUNDLE_MAX_BYTES bytes — refusing it"
      rc=1
    else
      svc_must "closing the bundle" sudo chmod 0600 "$bundle" || rc=1
    fi
  fi
  fm_as_workspace_owner rm -rf "$spool"
  if [ "$rc" = 0 ]; then
    svc_must "verifying the bundle" src_git bundle verify --quiet "$bundle" \
      && svc_must "fetching $TWIN_COMMIT into $SRC_GIT" src_git -c transfer.fsckObjects=true \
           fetch --quiet --no-tags "$bundle" "refs/fm/pin:refs/fm/$TWIN_COMMIT" || rc=1
  fi
  sudo rm -rf "$stage"
  [ "$rc" = 0 ] || return 1
  got="$(src_git rev-parse --verify --quiet "refs/fm/$TWIN_COMMIT^{commit}")" || got=""
  if [ "$got" != "$TWIN_COMMIT" ]; then
    src_git update-ref -d "refs/fm/$TWIN_COMMIT" 2>/dev/null || true
    fm_err "the fetched commit is '${got:-nothing}', not the pinned $TWIN_COMMIT"
    return 1
  fi
  fm_ok "$SRC_GIT holds $TWIN_COMMIT"
}

# The pinned commit's project files, out of root's repository, when the venv is
# not already built from them. Prints "changed" when it copied.
install_project() {
  local listing stage
  if venv_current; then
    fm_ok "$VENV_DIR already fm-twin $TWIN_COMMIT" >&2
    return 0
  fi
  listing="$(src_git ls-tree -r "$TWIN_COMMIT" -- "${SOURCE_FILES[@]}")" \
    || { fm_err "could not list fm-twin at $TWIN_COMMIT"; return 1; }
  printf '%s\n' "$listing" | svc_tree_ok || { fm_err "fm-twin at $TWIN_COMMIT is refused — nothing extracted"; return 1; }
  stage="$(sudo mktemp -d "$R$FM_TWIN_ROOT/.project.XXXXXX")" || { fm_err "creating a staging directory failed"; return 1; }
  if ! src_git archive --format=tar "$TWIN_COMMIT" "${SOURCE_FILES[@]}" \
       | sudo tar -x --no-same-owner --no-same-permissions -C "$stage"; then
    sudo rm -rf "$stage"
    fm_err "extracting fm-twin at $TWIN_COMMIT failed"
    return 1
  fi
  svc_seal_tree "$R" "$stage" "$PROJECT_DIR" >&2 || { sudo rm -rf "$stage"; return 1; }
  fm_ok "$PROJECT_DIR at $TWIN_COMMIT (root:root, 755/644)" >&2
  echo changed
}

# The venv, then the marker that says which commit it was built from. Written
# last, so a build that fails part-way is redone on the next run.
build_venv() {
  svc_build_venv "$R" "$FM_TWIN_ROOT" "$FM_TWIN_UV_CACHE" || return 1
  [ -x "$R$ENTRYPOINT" ] || { fm_err "$ENTRYPOINT missing after the build"; return 1; }
  printf '%s\n' "$TWIN_COMMIT" | sudo tee "$R$COMMIT_MARKER" >/dev/null \
    || { fm_err "recording the installed commit failed"; return 1; }
  fm_ok "$VENV_DIR built from fm-twin $TWIN_COMMIT"
}

# Every robot's description out of the controllers image: one container, and
# one `docker cp` per robot, each streamed to a root-owned tar that is listed
# before anything is extracted. A symlink entry, followed by an entry through
# it, would have root write wherever the link points. Every archive is checked
# and extracted before the first moves into place. The marker is removed before
# the first seal and written after the last, so a seal that fails part-way
# leaves no marker and the next run copies them all again. Prints "changed"
# when it copied.
#
# The body is a subshell, so its trap removes the container and the staging
# directory however it ends, and touches none of the caller's state.
install_description() (
  local ref="$1" cid="" stage="" list robot dir path top urdf
  # shellcheck disable=SC2317,SC2329  # run by the trap
  cleanup() {
    if [ -n "$cid" ]; then docker rm "$cid" >/dev/null 2>&1 || true; fi
    if [ -n "$stage" ]; then sudo rm -rf "$stage"; fi
  }
  trap cleanup EXIT
  trap 'exit 1' INT TERM HUP
  if description_current "$ref"; then
    fm_ok "$DESCRIPTION_ROOT already from $ref" >&2
    return 0
  fi
  list="$(robot_list)" || return 1
  cid="$(docker create "$ref" 2>/dev/null)" \
    || { cid=""; fm_err "creating a container of $ref failed"; return 1; }
  # mktemp makes the staging directory root's alone (0700), so only root can
  # see into it.
  stage="$(sudo mktemp -d "$R$FM_TWIN_ROOT/.description.XXXXXX")" \
    || { stage=""; fm_err "creating a staging directory failed"; return 1; }
  while IFS='|' read -r -u 3 robot dir path top urdf; do
    docker cp "$cid:$path" - | sudo tee "$stage/$dir.tar" >/dev/null \
      || { fm_err "copying $path out of $ref failed"; return 1; }
  done 3<<<"$list"
  while IFS='|' read -r -u 3 robot dir path top urdf; do
    stage_description "$ref" "$stage" "$robot" "$dir" "$path" "$top" "$urdf" || return 1
  done 3<<<"$list"
  svc_must "removing $DESCRIPTION_MARKER" sudo rm -f "$R$DESCRIPTION_MARKER" >&2 || return 1
  while IFS='|' read -r -u 3 robot dir path top urdf; do
    svc_seal_tree "$R" "$stage/$dir.x/$top" "$DESCRIPTION_ROOT/$dir" >&2 || return 1
  done 3<<<"$list"
  printf '%s\n' "$ref" | sudo tee "$R$DESCRIPTION_MARKER" >/dev/null \
    || { fm_err "recording the descriptions' image failed"; return 1; }
  fm_ok "$DESCRIPTION_ROOT copied from $ref" >&2
  echo changed
)

# stage_description REF STAGE ROBOT DIR PATH TOP URDF — check STAGE/DIR.tar,
# ROBOT's archive of PATH, with every entry under its top directory TOP, and
# extract it to STAGE/DIR.x, where TOP/URDF must then be. The caller removes
# STAGE.
stage_description() {
  local ref="$1" stage="$2" robot="$3" dir="$4" path="$5" top="$6" urdf="$7"
  local tarball="$2/$4.tar" listing names
  if ! listing="$(sudo tar -tvf "$tarball")" || ! names="$(sudo tar -tf "$tarball")"; then
    fm_err "the $robot description in $ref is not a readable tar — nothing extracted"
    return 1
  fi
  if ! printf '%s\n' "$listing" | svc_tar_ok || ! tar_names_ok "$names" "$top"; then
    fm_err "the $robot description in $ref is refused — nothing extracted"
    return 1
  fi
  if ! { svc_must "creating the $robot description's staging directory" \
           sudo install -d -m 0700 "$stage/$dir.x" \
      && svc_must "extracting the $robot description" \
           sudo tar -x --no-same-owner --no-same-permissions --no-overwrite-dir \
             -f "$tarball" -C "$stage/$dir.x"; } \
     || ! sudo test -f "$stage/$dir.x/$top/$urdf"; then
    fm_err "$ref has no $path/$urdf"
    return 1
  fi
}

# tar_names_ok NAMES TOP — 0 when every member name sits under TOP, the
# archive's top directory: relative, and with no '..' component.
tar_names_ok() {
  local name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    case "/$name/" in
      */../*) fm_err "refusing an archive entry with '..': $name"; return 1 ;;
    esac
    case "$name" in
      "$2" | "$2"/*) ;;
      *) fm_err "refusing an archive entry outside $2/: $name"; return 1 ;;
    esac
  done <<<"$1"
}

# install_unit PATH TEXT — prints "changed" when the unit was written.
install_unit() {
  local rc=0
  svc_install_file "$R" "$FM_TWIN_ROOT" "$1" "$2" >&2 || rc=$?
  case "$rc" in
    0) svc_must "reloading systemd" sudo systemctl daemon-reload >&2 || return 1; echo changed ;;
    3) ;;
    *) return 1 ;;
  esac
}

do_install() {
  if [ "${1:-}" = "--dry-run" ]; then
    dry_run_plan
    return
  fi

  local ref name rc=0 project description text robot_text="" unit robot_unit="" uv_sha twins
  ref="$(image_ref)" || return 1
  name="$(host_name)" || return 1
  text="$(render "$name")" || return 1
  robot_text="$(render_robot)" || rc=$?
  case "$rc" in
    0) ;;
    2) fm_warn "$(no_robot_entry) — installing the sim twin alone" ;;
    *) return 1 ;;
  esac
  rc=0
  commit_pinned || rc=$?
  [ "$rc" = 2 ] && return 1
  if [ "$rc" = 1 ]; then
    fm_warn "no fm-twin commit pinned (FM_TWIN_COMMIT_DEFAULT) — no twin installed"
    return 0
  fi
  fm_has_cmd systemctl || { fm_err "no systemctl — the twin is a systemd service"; return 1; }
  fm_has_docker || { fm_err "docker is not reachable — run the docker step first"; return 1; }
  if ! image_pulled "$ref"; then
    fm_skip "$ref not pulled — the twin masks the robots the sim runs, from that image; pull it with: FM_SIM_CONTROLLERS=1 ./install.sh --${FM_ROLE:-workstation} --only sim, then re-run --only twin"
    return 0
  fi

  rc=0
  fetch_source || rc=$?
  case "$rc" in 0) ;; 2) return 0 ;; *) return 1 ;; esac
  svc_ensure_account "$FM_TWIN_USER" || return 1
  project="$(install_project)" || return 1
  uv_sha="$(svc_uv_sha "$TEST_UV_SHA")" || return 1
  svc_install_uv "$R" "$FM_TWIN_ROOT" "$uv_sha" || return 1
  if [ -n "$project" ]; then
    build_venv || return 1
  fi
  description="$(install_description "$ref")" || return 1
  unit="$(install_unit "$UNIT_PATH" "$text")" || return 1
  if [ -n "$robot_text" ]; then
    robot_unit="$(install_unit "$ROBOT_UNIT_PATH" "$robot_text")" || return 1
  fi

  if [ ! -f "$R$COMMS_ENV" ]; then
    fm_skip "$COMMS_ENV missing — install fm-comms through fm_ros2, then re-run: ./install.sh --${FM_ROLE:-workstation} --only twin"
    return 0
  fi
  svc_must "enabling $FM_TWIN_UNIT" sudo systemctl enable "$FM_TWIN_UNIT" || return 1
  if [ -n "$project$description$unit" ]; then
    svc_must "restarting $FM_TWIN_UNIT" sudo systemctl restart "$FM_TWIN_UNIT" || return 1
  else
    svc_must "starting $FM_TWIN_UNIT" sudo systemctl start "$FM_TWIN_UNIT" || return 1
  fi
  # A robot twin the host agent started keeps running the old code until it
  # restarts; try-restart touches only the instances that are running.
  if [ -n "$robot_text" ] && [ -n "$project$description$robot_unit" ]; then
    twins="$(robot_twins)"
    if [ -n "$twins" ]; then
      # shellcheck disable=SC2086  # one unit name per word
      svc_must "restarting running robot twins" sudo systemctl try-restart $twins || return 1
    fi
  fi
  fm_ok "$FM_TWIN_UNIT enabled and running — the twin for sim:$name, on $(fm_machine_namespace "$name")/twin/points"
  if [ -n "$robot_text" ]; then
    fm_ok "$FM_TWIN_ROBOT_UNIT installed, not enabled — the host agent starts an instance per robot"
  fi
}

# --- Uninstall ----------------------------------------------------------------

# remove_tree PATH — rm -rf one of the step's own trees, named exactly.
remove_tree() { svc_remove_tree "$R" twin "$1" /opt/fm-twin /var/cache/fm-twin; }

do_uninstall() {
  if [ -f "$R$UNIT_PATH" ]; then
    svc_must "disabling $FM_TWIN_UNIT" sudo systemctl disable --now "$FM_TWIN_UNIT" || return 1
    svc_must "removing $UNIT_PATH" sudo rm -f "$R$UNIT_PATH" || return 1
    svc_must "reloading systemd" sudo systemctl daemon-reload || return 1
    fm_ok "$FM_TWIN_UNIT removed"
  else
    fm_skip "$FM_TWIN_UNIT not installed"
  fi
  if [ -f "$R$ROBOT_UNIT_PATH" ]; then
    local twins
    twins="$(robot_twins)"
    if [ -n "$twins" ]; then
      # shellcheck disable=SC2086  # one unit name per word
      svc_must "stopping robot twins" sudo systemctl stop $twins || return 1
    fi
    svc_must "removing $ROBOT_UNIT_PATH" sudo rm -f "$R$ROBOT_UNIT_PATH" || return 1
    svc_must "reloading systemd" sudo systemctl daemon-reload || return 1
    fm_ok "$FM_TWIN_ROBOT_UNIT removed"
  fi
  if getent passwd "$FM_TWIN_USER" >/dev/null 2>&1; then
    svc_must "removing account $FM_TWIN_USER" sudo userdel "$FM_TWIN_USER" || return 1
    fm_ok "account $FM_TWIN_USER removed"
  fi
  remove_tree "$FM_TWIN_ROOT" || return 1
  remove_tree "$FM_TWIN_UV_CACHE" || return 1
  return 0
}

fm_dispatch "$@"
