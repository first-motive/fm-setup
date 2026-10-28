#!/usr/bin/env bash
#
# host-agent — publish this workstation's load on the fabric.
#
# fm-host-agent puts the host's CPU, memory, GPU and disk load, and who is using
# each, under fm/host/<host>/, where fm-desktop's Devices view reads it. Several
# people share the tower, and this is how they see whether it is free without
# opening a session on it. This step puts the agent on the host:
#
#   the agent      this checkout's host-agent/, copied into a root-owned tree
#                  with a root-built venv, run by systemd as its own account
#   the scan       fm-host-disk-scan.service, a root oneshot that sums disk use
#                  under /data and /home by owner and writes a report to
#                  FM_HOST_AGENT_STATE
#   the rule       a polkit rule that lets the agent's account start that one
#                  unit, and start, stop or restart fm-sim-agent.service, and
#                  nothing else
#
# The agent never holds a privilege. Its account is in no group — not docker,
# not fm — and it reads only what any account may: /proc, the GPU driver, and
# statvfs. Seeing every account's files needs root, so that one job runs as a
# root unit the agent may start but not change: the unit, the rule and the code
# it runs are root-owned, and the rule names the unit and the verb.
#
# The code comes from this checkout, which root already trusts — it sources this
# script — and is copied out of it, so the service never runs from the
# group-writable workspace. The venv is built as root with the uv the sim step
# also pins, downloaded at FM_UV_VERSION and checked against
# FM_SIM_UV_SHA256_MAP, the project installed non-editable.
#
# install exits 1 on a failure, and 0 when it stops at a gate a person clears
# later — /etc/fm-comms.env not there yet — and says which.
#
#   bash scripts/steps/93-host-agent.sh install --dry-run    print the plan, change nothing
#
# Test hooks, for scripts/dev/test-host-agent.sh only and refused without
# FM_HOST_AGENT_TEST=1: FM_HOST_AGENT_TEST_ROOT prefixes every path the step
# writes (and must sit under the temp directory), and FM_HOST_AGENT_TEST_UV_SHA256
# replaces the uv checksum, refused unless a valid test root is set too.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$_here/../.." && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$FM_ROOT/lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$FM_ROOT/scripts/manifest.sh"

fm_require_linux

# Literal, because the drift audit reads this line with sed. FM_HOST_AGENT_UNIT,
# then FM_HOST_DISK_SCAN_UNIT.
# shellcheck disable=SC2034
FM_UNITS=(fm-host-agent.service fm-host-disk-scan.service)

# test_knob NAME — echo a test hook's value, or refuse it outside a test run.
test_knob() {
  local value="${!1:-}"
  [ -n "$value" ] || return 0
  [ "${FM_HOST_AGENT_TEST:-0}" = 1 ] || { fm_err "$1 is a test hook and needs FM_HOST_AGENT_TEST=1 — refusing"; return 1; }
  printf '%s\n' "$value"
}

# test_root_ok PREFIX — 0 when PREFIX sits under the temp directory and holds no '..'.
# tradeoff: sim-lib.sh's sim_test_root_ok, copied with this step's hook names, as
# are must, install_uv and build_venv from 91-sim.sh; a third step with a pinned
# uv and test hooks is the cue to move them into scripts/internal/.
test_root_ok() {
  local prefix="$1" tmp="${TMPDIR:-/tmp}"
  tmp="${tmp%/}"
  [ -n "$tmp" ] || { fm_err "no temp directory to hold FM_HOST_AGENT_TEST_ROOT — refusing"; return 1; }
  case "$prefix" in *..*) fm_err "FM_HOST_AGENT_TEST_ROOT must not hold '..': $prefix"; return 1 ;; esac
  [ "${prefix#"$tmp"/}" != "$prefix" ] && [ -n "${prefix#"$tmp"/}" ] && return 0
  fm_err "FM_HOST_AGENT_TEST_ROOT must sit under $tmp/: $prefix"
  return 1
}

R="$(test_knob FM_HOST_AGENT_TEST_ROOT)" || exit 1
if [ -n "$R" ]; then test_root_ok "$R" || exit 1; fi
TEST_UV_SHA="$(test_knob FM_HOST_AGENT_TEST_UV_SHA256)" || exit 1
if [ -n "$TEST_UV_SHA" ] && [ -z "$R" ]; then
  fm_err "FM_HOST_AGENT_TEST_UV_SHA256 needs FM_HOST_AGENT_TEST_ROOT — refusing"
  exit 1
fi

SOURCE_DIR="$FM_ROOT/host-agent"
# What the venv is built from. Tests, caches and the dev venv stay behind.
SOURCE_FILES=(pyproject.toml uv.lock README.md src)
COMMS_ENV=/etc/fm-comms.env
UNIT_DIR=/etc/systemd/system
PROJECT_DIR="$FM_HOST_AGENT_ROOT/project"
VENV_DIR="$FM_HOST_AGENT_ROOT/venv"
UV_BIN="$FM_HOST_AGENT_ROOT/bin/uv"
ENTRYPOINT="$VENV_DIR/bin/fm-host-agent"
SCAN_ENTRYPOINT="$VENV_DIR/bin/fm-host-disk-scan"
SOURCE_MARKER="$FM_HOST_AGENT_ROOT/.fm-source-sha256"
UV_MARKER="$FM_HOST_AGENT_ROOT/bin/.uv-sha256"
# Source file under host-agent/systemd → where it is installed.
INSTALLED=(
  "$FM_HOST_AGENT_UNIT|$UNIT_DIR/$FM_HOST_AGENT_UNIT"
  "$FM_HOST_DISK_SCAN_UNIT|$UNIT_DIR/$FM_HOST_DISK_SCAN_UNIT"
  "$(basename "$FM_HOST_AGENT_POLKIT_RULE")|$FM_HOST_AGENT_POLKIT_RULE"
)

# must WHAT CMD… — run CMD; on failure say WHAT failed and return 1. Every
# privileged command goes through this or an explicit `|| {…}`, because errexit
# does not hold inside a function its caller tests with `||`.
must() {
  local what="$1"; shift
  "$@" && return 0
  fm_err "$what failed"
  return 1
}

# The one hash that says whether the installed project is this checkout's.
source_sha() {
  (cd "$SOURCE_DIR" && find "${SOURCE_FILES[@]}" -type f -not -path '*/__pycache__/*' -print0 \
    | LC_ALL=C sort -z | xargs -0 sha256sum) | sha256sum | cut -d' ' -f1
}

# The uv tarball's pinned sha256 for this machine's architecture.
uv_sha() {
  local arch entry
  if [ -n "$TEST_UV_SHA" ]; then printf '%s\n' "$TEST_UV_SHA"; return 0; fi
  arch="$(uname -m)"
  for entry in "${FM_SIM_UV_SHA256_MAP[@]}"; do
    [ "${entry%%|*}" = "$arch" ] && { printf '%s\n' "${entry#*|}"; return 0; }
  done
  fm_err "no uv checksum pinned for $arch — add it to FM_SIM_UV_SHA256_MAP"
  return 1
}

same_file() { [ -f "$1" ] && cmp -s "$1" "$2"; }
in_any_group() { [ "$(id -nG "$FM_HOST_AGENT_USER" 2>/dev/null)" != "$FM_HOST_AGENT_USER" ]; }

# --- Check --------------------------------------------------------------------

do_check() {
  local entry tree loose
  if getent passwd "$FM_HOST_AGENT_USER" >/dev/null 2>&1; then
    fm_ok "account $FM_HOST_AGENT_USER present"
    if in_any_group; then
      fm_warn "$FM_HOST_AGENT_USER is in groups beyond its own: $(id -nG "$FM_HOST_AGENT_USER") — it should hold none"
    fi
  else
    fm_warn "account $FM_HOST_AGENT_USER missing"
  fi
  if [ "$(cat "$R$SOURCE_MARKER" 2>/dev/null)" = "$(source_sha)" ]; then
    fm_ok "$PROJECT_DIR is this checkout's host-agent/"
  else
    fm_warn "$PROJECT_DIR is not this checkout's host-agent/"
  fi
  if [ -x "$R$UV_BIN" ] && [ "$(cat "$R$UV_MARKER" 2>/dev/null)" = "$(uv_sha 2>/dev/null)" ]; then
    fm_ok "$UV_BIN is the pinned uv $FM_UV_VERSION"
  else
    fm_warn "$UV_BIN is not the pinned uv $FM_UV_VERSION"
  fi
  if [ -x "$R$ENTRYPOINT" ]; then fm_ok "$ENTRYPOINT present"; else fm_warn "$ENTRYPOINT missing"; fi
  # The disk scan runs this tree as root and writes into the state directory,
  # so a file anyone else can change is a way to root.
  for tree in "$FM_HOST_AGENT_ROOT" "$FM_HOST_AGENT_STATE"; do
    [ -d "$R$tree" ] || { fm_warn "$tree missing"; continue; }
    loose="$(find "$R$tree" ! -type l \( -perm /022 -o ! -user root \) -print -quit 2>/dev/null)"
    if [ -z "$loose" ]; then
      fm_ok "$tree is root's alone"
    else
      fm_warn "${loose#"$R"} is not root-owned or is writable by others — the disk scan runs as root; re-run install, which resets both trees"
    fi
  done
  for entry in "${INSTALLED[@]}"; do
    if same_file "$R${entry#*|}" "$SOURCE_DIR/systemd/${entry%%|*}"; then
      fm_ok "${entry#*|} installed and current"
    else
      fm_warn "${entry#*|} missing or out of date — re-run: ./install.sh --${FM_ROLE:-workstation} --only host-agent"
    fi
  done
  if fm_has_cmd systemctl && systemctl is-active --quiet "$FM_HOST_AGENT_UNIT" 2>/dev/null; then
    fm_ok "$FM_HOST_AGENT_UNIT active"
  else
    fm_warn "$FM_HOST_AGENT_UNIT not active"
  fi
  return 0
}

# --- Install ------------------------------------------------------------------

dry_run_plan() {
  local entry
  fm_log "dry run — nothing on this host changes"
  fm_info "would create system account $FM_HOST_AGENT_USER (no home, no login, no groups)"
  fm_info "would create $FM_HOST_AGENT_STATE (root:root, 755) for the disk scan's report"
  fm_info "would copy   $SOURCE_DIR (${SOURCE_FILES[*]}) to $PROJECT_DIR (root:root, 755/644)"
  fm_info "would fetch  uv $FM_UV_VERSION to $UV_BIN, checked against sha256 $(uv_sha)"
  fm_info "would build  $VENV_DIR as root (uv sync --frozen --no-editable)"
  for entry in "${INSTALLED[@]}"; do
    fm_info "would write  ${entry#*|} from host-agent/systemd/${entry%%|*} (root:root, 644)"
  done
  fm_info "would enable and start $FM_HOST_AGENT_UNIT once $COMMS_ENV exists"
}

ensure_account() {
  if getent passwd "$FM_HOST_AGENT_USER" >/dev/null 2>&1; then
    fm_ok "account $FM_HOST_AGENT_USER present"
    return 0
  fi
  fm_log "creating system account $FM_HOST_AGENT_USER"
  must "creating account $FM_HOST_AGENT_USER" sudo useradd --system --user-group --no-create-home \
    --home-dir /nonexistent --shell /usr/sbin/nologin "$FM_HOST_AGENT_USER" || return 1
  fm_ok "account $FM_HOST_AGENT_USER created"
}

# Copy host-agent/ out of this checkout into the root-owned tree. The marker is
# written last, so a copy that fails part-way is redone on the next run.
# Prints "changed" when it copied.
install_project() {
  local sha="$1" root="$R$FM_HOST_AGENT_ROOT" stage
  if [ "$(cat "$R$SOURCE_MARKER" 2>/dev/null)" = "$sha" ] && [ -d "$R$PROJECT_DIR" ] && [ -x "$R$ENTRYPOINT" ]; then
    fm_ok "$PROJECT_DIR already this checkout's host-agent/" >&2
    return 0
  fi
  must "creating $FM_HOST_AGENT_ROOT" sudo install -d -o root -g root -m 0755 "$root" >&2 || return 1
  stage="$(sudo mktemp -d "$root/.project.XXXXXX")" || { fm_err "creating a staging directory failed"; return 1; }
  if ! tar -C "$SOURCE_DIR" --exclude=__pycache__ -cf - "${SOURCE_FILES[@]}" \
       | sudo tar -x --no-same-owner --no-same-permissions -C "$stage"; then
    sudo rm -rf "$stage"
    fm_err "copying $SOURCE_DIR failed"
    return 1
  fi
  if ! { must "handing $PROJECT_DIR to root" sudo chown -R root:root "$stage" \
      && must "setting directory modes" sudo find "$stage" -type d -exec chmod 0755 {} + \
      && must "setting file modes" sudo find "$stage" -type f -exec chmod 0644 {} + \
      && must "removing the old $PROJECT_DIR" sudo rm -rf "$R$PROJECT_DIR" \
      && must "moving the new $PROJECT_DIR into place" sudo mv "$stage" "$R$PROJECT_DIR"; } >&2; then
    sudo rm -rf "$stage"
    return 1
  fi
  fm_ok "$PROJECT_DIR copied from $SOURCE_DIR (root:root, 755/644)" >&2
  echo changed
}

# Astral's release tarball at the pinned version, checked before it is unpacked.
install_uv() {
  local sha arch stage actual
  sha="$(uv_sha)" || return 1
  if [ -x "$R$UV_BIN" ] && [ "$(cat "$R$UV_MARKER" 2>/dev/null)" = "$sha" ]; then
    fm_ok "$UV_BIN is the pinned uv $FM_UV_VERSION"
    return 0
  fi
  arch="$(uname -m)"
  must "creating $(dirname "$UV_BIN")" sudo install -d -o root -g root -m 0755 "$(dirname "$R$UV_BIN")" || return 1
  stage="$(sudo mktemp -d "$R$FM_HOST_AGENT_ROOT/.uv.XXXXXX")" || { fm_err "creating a staging directory failed"; return 1; }
  fm_log "fetching uv $FM_UV_VERSION ($arch)"
  if ! must "downloading uv $FM_UV_VERSION" sudo curl -fsSL --proto '=https' --proto-redir '=https' -o "$stage/uv.tar.gz" \
       "https://github.com/astral-sh/uv/releases/download/$FM_UV_VERSION/uv-$arch-unknown-linux-gnu.tar.gz"; then
    sudo rm -rf "$stage"
    return 1
  fi
  actual="$(sudo sha256sum "$stage/uv.tar.gz" | cut -d' ' -f1)" || actual=""
  if [ "$actual" != "$sha" ]; then
    sudo rm -rf "$stage"
    fm_err "uv $FM_UV_VERSION checksum mismatch — expected $sha, got ${actual:-nothing}; not installed"
    return 1
  fi
  if ! { must "unpacking uv" sudo tar -xzf "$stage/uv.tar.gz" --no-same-owner -C "$stage" \
      && must "installing $UV_BIN" sudo install -o root -g root -m 0755 \
           "$stage/uv-$arch-unknown-linux-gnu/uv" "$R$UV_BIN"; }; then
    sudo rm -rf "$stage"
    return 1
  fi
  sudo rm -rf "$stage"
  printf '%s\n' "$sha" | sudo tee "$R$UV_MARKER" >/dev/null \
    || { fm_err "recording the uv checksum failed"; return 1; }
  fm_ok "$UV_BIN is uv $FM_UV_VERSION (sha256 verified)"
}

# secure_trees — root:root and writable by root alone, on every run. A tree an
# earlier run, or a person, left otherwise would survive the skips above, and
# the disk scan runs this code as root.
secure_trees() {
  local tree
  for tree in "$FM_HOST_AGENT_ROOT" "$FM_HOST_AGENT_STATE"; do
    [ -d "$R$tree" ] || continue
    { must "handing $tree to root" sudo chown -R root:root "$R$tree" \
      && must "closing $tree to writers" sudo chmod -R go-w "$R$tree"; } || return 1
  done
}

# Build the venv as root, from the root-owned project, with nothing inherited:
# no uv config file, no index override, no PATH beyond the system's.
build_venv() {
  local sha="$1"
  must "creating $FM_HOST_AGENT_UV_CACHE" sudo install -d -o root -g root -m 0700 "$R$FM_HOST_AGENT_UV_CACHE" || return 1
  fm_log "building $VENV_DIR (as root, from $PROJECT_DIR)"
  must "building $VENV_DIR" sudo env -i PATH=/usr/bin:/bin HOME=/nonexistent UV_NO_CONFIG=1 \
    "UV_PROJECT_ENVIRONMENT=$R$VENV_DIR" "UV_CACHE_DIR=$R$FM_HOST_AGENT_UV_CACHE" \
    "UV_PYTHON=$FM_CLI_PYTHON" UV_PYTHON_DOWNLOADS=never \
    "$R$UV_BIN" sync --quiet --frozen --no-dev --no-editable --directory "$R$PROJECT_DIR" || return 1
  [ -x "$R$ENTRYPOINT" ] && [ -x "$R$SCAN_ENTRYPOINT" ] \
    || { fm_err "$ENTRYPOINT or $SCAN_ENTRYPOINT missing after the build"; return 1; }
  must "setting venv modes" sudo chmod -R u+rwX,go+rX,go-w "$R$VENV_DIR" || return 1
  printf '%s\n' "$sha" | sudo tee "$R$SOURCE_MARKER" >/dev/null \
    || { fm_err "recording the installed source failed"; return 1; }
  fm_ok "$VENV_DIR built"
}

# install_files — the units and the rule, each root:root 0644. Prints "changed"
# when any of them was written.
install_files() {
  local entry src dest changed=""
  for entry in "${INSTALLED[@]}"; do
    src="$SOURCE_DIR/systemd/${entry%%|*}"
    dest="$R${entry#*|}"
    if same_file "$dest" "$src"; then
      fm_ok "${entry#*|} current" >&2
      continue
    fi
    { must "creating $(dirname "${entry#*|}")" sudo install -d -m 0755 "$(dirname "$dest")" \
      && must "writing ${entry#*|}" sudo install -o root -g root -m 0644 "$src" "$dest"; } >&2 || return 1
    fm_ok "wrote ${entry#*|}" >&2
    changed=changed
  done
  if [ -n "$changed" ]; then
    must "reloading systemd" sudo systemctl daemon-reload >&2 || return 1
    echo changed
  fi
}

do_install() {
  if [ "${1:-}" = "--dry-run" ]; then
    dry_run_plan
    return
  fi

  local sha project files odd
  fm_has_cmd systemctl || { fm_err "no systemctl — the host agent is a systemd service"; return 1; }
  [ -d "$SOURCE_DIR/src" ] || { fm_err "$SOURCE_DIR is not in this checkout"; return 1; }
  # Root copies and builds whatever is there, so only plain files and directories:
  # a symlink would bring whatever it names into a venv the agent can read.
  odd="$(cd "$SOURCE_DIR" && find "${SOURCE_FILES[@]}" ! -type f ! -type d -print -quit)"
  [ -z "$odd" ] || { fm_err "host-agent/$odd is not a plain file — refusing to build from it"; return 1; }
  sha="$(source_sha)"

  ensure_account || return 1
  must "creating $FM_HOST_AGENT_STATE" sudo install -d -o root -g root -m 0755 "$R$FM_HOST_AGENT_STATE" || return 1
  project="$(install_project "$sha")" || return 1
  install_uv || return 1
  if [ -n "$project" ] || [ "$(cat "$R$SOURCE_MARKER" 2>/dev/null)" != "$sha" ]; then
    build_venv "$sha" || return 1
  fi
  secure_trees || return 1
  # Asked before the rule is written, which creates its directory either way.
  if [ ! -d "$R$(dirname "$FM_HOST_AGENT_POLKIT_RULE")" ] || ! fm_has_cmd pkcheck; then
    fm_warn "polkit is not installed — the agent runs, but cannot start $FM_HOST_DISK_SCAN_UNIT"
  fi
  files="$(install_files)" || return 1
  if [ ! -f "$R$COMMS_ENV" ]; then
    fm_skip "$COMMS_ENV missing — install fm-comms through fm_ros2, then re-run: ./install.sh --${FM_ROLE:-workstation} --only host-agent"
    return 0
  fi
  must "enabling $FM_HOST_AGENT_UNIT" sudo systemctl enable "$FM_HOST_AGENT_UNIT" || return 1
  if [ -n "$project$files" ]; then
    must "restarting $FM_HOST_AGENT_UNIT" sudo systemctl restart "$FM_HOST_AGENT_UNIT" || return 1
  else
    must "starting $FM_HOST_AGENT_UNIT" sudo systemctl start "$FM_HOST_AGENT_UNIT" || return 1
  fi
  fm_ok "$FM_HOST_AGENT_UNIT enabled and running — publishes fm/host/$(fm_machine_namespace 2>/dev/null || echo '<host>')/load"
}

# --- Uninstall ----------------------------------------------------------------

# remove_tree PATH — rm -rf one of the step's own trees, named exactly. Literal
# rather than the manifest's variables, so an edit there cannot widen a root rm.
remove_tree() {
  case "$1" in
    /opt/fm-host-agent | /var/cache/fm-host-agent | /var/lib/fm-host-agent) ;;
    *) fm_warn "not removing $1 — not one of the host-agent step's trees; remove it by hand"; return 0 ;;
  esac
  if [ -d "$R$1" ]; then
    must "removing $1" sudo rm -rf "$R$1" || return 1
    fm_ok "$1 removed"
  fi
}

do_uninstall() {
  local entry removed=0
  if [ -f "$R$UNIT_DIR/$FM_HOST_AGENT_UNIT" ]; then
    must "disabling $FM_HOST_AGENT_UNIT" sudo systemctl disable --now "$FM_HOST_AGENT_UNIT" || return 1
  fi
  for entry in "${INSTALLED[@]}"; do
    if [ -f "$R${entry#*|}" ]; then
      must "removing ${entry#*|}" sudo rm -f "$R${entry#*|}" || return 1
      fm_ok "${entry#*|} removed"
      removed=1
    fi
  done
  if [ "$removed" = 1 ]; then
    must "reloading systemd" sudo systemctl daemon-reload || return 1
  else
    fm_skip "host agent not installed"
  fi
  if getent passwd "$FM_HOST_AGENT_USER" >/dev/null 2>&1; then
    must "removing account $FM_HOST_AGENT_USER" sudo userdel "$FM_HOST_AGENT_USER" || return 1
    fm_ok "account $FM_HOST_AGENT_USER removed"
  fi
  remove_tree "$FM_HOST_AGENT_ROOT" || return 1
  remove_tree "$FM_HOST_AGENT_UV_CACHE" || return 1
  remove_tree "$FM_HOST_AGENT_STATE" || return 1
  return 0
}

fm_dispatch "$@"
