#!/usr/bin/env bash
#
# sim — make this workstation a sim host: the fm-sim image and the sim agent.
#
# A sim host is driven over Zenoh, not over SSH. fm-sim's agent serves the run
# control verbs under fm/sim/<host>/* and starts each run as a container of the
# fm-sim image. This step puts both on the host:
#
#   the image    ghcr.io/first-motive/fm-sim, by the digest the manifest pins;
#                with FM_SIM_CONTROLLERS=1, the private fm-sim-controllers
#                overlay by its own pin, which needs docker login ghcr.io: the
#                operator's own on a workstation; on the sim-cloud role, one
#                this step makes from a GHCR token in SSM and removes again
#   the agent    fm-sim's agent/ at the commit the manifest pins, in a
#                root-owned tree with a root-built venv, run by systemd as its
#                own account
#
# The agent's account is in the docker group, and that group is root-equivalent:
# a member can start a container that mounts the host's filesystem. This
# checkout of fm-setup is trusted as it is for every step — root sources it.
# Beyond that, the three things this step brings in for the agent — its code,
# the uv that builds its venv, and its unit template — come only from pinned
# sources root fetches and keeps in root-owned places:
#
#   - Root fetches the pinned commit itself, from GitHub, into a bare repository
#     under FM_SIM_AGENT_ROOT, with a scrubbed environment and replace objects
#     off. The workspace's fm-sim checkout, if there is one, is never read.
#   - The commit's agent/ tree is listed first and refused if it holds anything
#     but plain files, then copied out with `git archive` into a tree that is
#     root:root, directories 755 and files 644.
#   - Root builds the venv with a uv downloaded at FM_UV_VERSION and checked
#     against FM_SIM_UV_SHA256_MAP, the project installed non-editable, so the
#     service starts the venv's entrypoint and runs no uv and no build backend.
#   - The unit comes from fm-sim's template only if it passes the allowlist in
#     scripts/internal/sim-lib.sh, and its ExecStart is replaced by the
#     installed entrypoint and this host's flags.
#   - The docker grant is asked for (auto-declined under NONINTERACTIVE; given
#     without asking on the sim-cloud role run unattended, its bootstrap), and
#     neither the grant nor the enable happens without a pinned image digest.
#
# install exits 1 on a failure: a malformed pin, a fetch or checksum that does
# not match, a refused template or tree, any privileged command that fails. It
# exits 0 when it stops at a gate a person clears later — no commit or digest
# pinned, the docker grant declined, /etc/fm-comms.env not there yet — and says
# which.
#
# Isaac Sim's readiness is 90-isaac-sim's check. The bridge is fm-comms': the
# card's `workload: "sim"` selects bridge-sim.json5 when fm_ros2 renders it. A
# workstation keeps its own Humble bridge, which never discovers the Jazzy nodes
# of a sim run, so its sim topics need fm-comms' second, Jazzy bridge
# (`install.sh --role bridge-sim`, from FM_COMMS_TAG on). fm-setup does not
# manage fm-comms on a workstation — fm_ros2 does — so this step prints the
# command rather than running it. It reports any other workload without
# changing the card.
#
#   bash scripts/steps/91-sim.sh install --dry-run    print the plan, change nothing
#
# Test hooks, for scripts/dev/test-sim.sh only and refused without FM_SIM_TEST=1:
# FM_SIM_TEST_ROOT prefixes every path the step writes (and must sit under the
# temp directory). FM_SIM_TEST_SOURCE replaces the GitHub URL and
# FM_SIM_TEST_UV_SHA256 the uv checksum, and both are refused unless a valid
# FM_SIM_TEST_ROOT is set too. The unit's text never carries
# any of them.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$_here/../.." && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$FM_ROOT/lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$FM_ROOT/scripts/manifest.sh"
# shellcheck source=../internal/sim-lib.sh disable=SC1091
. "$FM_ROOT/scripts/internal/sim-lib.sh"
# shellcheck source=../internal/ghcr-lib.sh disable=SC1091
. "$FM_ROOT/scripts/internal/ghcr-lib.sh"

fm_require_linux

# Literal, because the drift audit reads this line with sed. It is FM_SIM_UNIT,
# then FM_COMMS_SIM_BRIDGE_UNIT: this step installs neither the bridge nor its
# unit, but it reports the unit, so the audit accounts for it here.
# shellcheck disable=SC2034
FM_UNITS=(fm-sim-agent.service fm-zenoh-bridge-sim.service)

# test_knob NAME — echo a test hook's value, or refuse it outside a test run.
test_knob() {
  local value="${!1:-}"
  [ -n "$value" ] || return 0
  [ "${FM_SIM_TEST:-0}" = 1 ] || { fm_err "$1 is a test hook and needs FM_SIM_TEST=1 — refusing"; return 1; }
  printf '%s\n' "$value"
}

R="$(test_knob FM_SIM_TEST_ROOT)" || exit 1
if [ -n "$R" ]; then sim_test_root_ok "$R" || exit 1; fi
SOURCE_URL="$(test_knob FM_SIM_TEST_SOURCE)" || exit 1
TEST_UV_SHA="$(test_knob FM_SIM_TEST_UV_SHA256)" || exit 1
# A source or checksum override only ever goes with a temp root, so neither can
# point a real install at another repository or another uv.
if { [ -n "$SOURCE_URL" ] || [ -n "$TEST_UV_SHA" ]; } && [ -z "$R" ]; then
  fm_err "FM_SIM_TEST_SOURCE and FM_SIM_TEST_UV_SHA256 need FM_SIM_TEST_ROOT — refusing"
  exit 1
fi
SOURCE_URL="${SOURCE_URL:-https://github.com/$FM_SIM_REPO.git}"

TEMPLATE_PATH=agent/systemd/fm-sim-agent.service.in
COMMS_ENV=/etc/fm-comms.env
UNIT_PATH="/etc/systemd/system/$FM_SIM_UNIT"
SRC_GIT="$FM_SIM_AGENT_ROOT/src.git"
PROJECT_DIR="$FM_SIM_AGENT_ROOT/project"
VENV_DIR="$FM_SIM_AGENT_ROOT/venv"
UV_BIN="$FM_SIM_AGENT_ROOT/bin/uv"
ENTRYPOINT="$VENV_DIR/bin/fm-sim-agent"
COMMIT_MARKER="$FM_SIM_AGENT_ROOT/.fm-commit"
UV_MARKER="$FM_SIM_AGENT_ROOT/bin/.uv-sha256"

# The pins, or values named on the command line to try something first. The
# sim-cloud role always names both, from its stack's host.env.
SIM_COMMIT="${FM_SIM_COMMIT:-$FM_SIM_COMMIT_DEFAULT}"

# Which image runs start from: the public fm-sim image, or, with
# FM_SIM_CONTROLLERS=1, its private controllers overlay at that image's own pin.
# DIGEST_VAR names the override, so a message says which variable to fix. Any
# other value of the switch is refused by image_ref, which every mode calls.
SIM_CONTROLLERS="${FM_SIM_CONTROLLERS:-0}"
if [ "$SIM_CONTROLLERS" = 1 ]; then
  SIM_IMAGE="$FM_SIM_CONTROLLERS_IMAGE"
  DIGEST_VAR=FM_SIM_CONTROLLERS_IMAGE_DIGEST
  SIM_DIGEST="${FM_SIM_CONTROLLERS_IMAGE_DIGEST:-$FM_SIM_CONTROLLERS_IMAGE_DIGEST_DEFAULT}"
else
  SIM_IMAGE="$FM_SIM_IMAGE"
  DIGEST_VAR=FM_SIM_IMAGE_DIGEST
  SIM_DIGEST="${FM_SIM_IMAGE_DIGEST:-$FM_SIM_IMAGE_DIGEST_DEFAULT}"
fi

# git with nothing inherited: no user or system config, no replace objects, no
# prompt, and a fixed PATH. Root runs it against its own repository only.
GIT_ENV=(env -i PATH=/usr/bin:/bin HOME=/nonexistent GIT_NO_REPLACE_OBJECTS=1
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0)
src_git()  { sudo "${GIT_ENV[@]}" git -c "safe.directory=$R$SRC_GIT" --git-dir="$R$SRC_GIT" "$@"; }
# The repository is root-owned and world-readable, so a report reads it plainly.
read_src_git() { "${GIT_ENV[@]}" git -c "safe.directory=$R$SRC_GIT" --git-dir="$R$SRC_GIT" "$@"; }

# must WHAT CMD… — run CMD; on failure say WHAT failed and return 1. Every
# privileged command goes through this or an explicit `|| {…}`, because errexit
# does not hold inside a function its caller tests with `||`.
must() {
  local what="$1"; shift
  "$@" && return 0
  fm_err "$what failed"
  return 1
}

# --- Pins ---------------------------------------------------------------------

# 0 when a commit is pinned and shaped like a full SHA; 1 when none is; 2 when
# one is malformed.
commit_pinned() {
  [ -n "$SIM_COMMIT" ] || return 1
  if ! printf '%s' "$SIM_COMMIT" | grep -Eq '^[0-9a-f]{40}$'; then
    fm_err "FM_SIM_COMMIT is malformed: '$SIM_COMMIT' (want a full 40-character SHA)"
    return 2
  fi
}

# The image reference runs use: the digest when one is pinned.
image_ref() {
  case "$SIM_CONTROLLERS" in
    0) ;;
    1) ;;
    *)
      fm_err "FM_SIM_CONTROLLERS is malformed: '$SIM_CONTROLLERS' (want 0 or 1)"
      return 1 ;;
  esac
  if [ -z "$SIM_DIGEST" ]; then
    printf '%s\n' "$SIM_IMAGE"
    return 0
  fi
  # grep matches line by line, so a value with a newline in it is refused first.
  if [[ "$SIM_DIGEST" == *$'\n'* ]] || ! printf '%s' "$SIM_DIGEST" | grep -Eq '^sha256:[0-9a-f]{64}$'; then
    fm_err "$DIGEST_VAR is malformed: '$SIM_DIGEST' (want sha256:<64 hex>)"
    return 1
  fi
  printf '%s@%s\n' "${SIM_IMAGE%:*}" "$SIM_DIGEST"
}

# With the controllers image chosen, say that it is private and how to reach it.
private_image_note() {
  [ "$SIM_CONTROLLERS" = 1 ] || return 0
  # The cloud host logs itself in with its stack's token (ghcr-lib.sh).
  ghcr_pull_needed && return 0
  fm_info "FM_SIM_CONTROLLERS=1: ${SIM_IMAGE%:*} is private — the pull needs docker login ghcr.io"
  fm_info "  with a token that can read first-motive packages; without one the pull fails and runs cannot start"
}

# The installed entrypoint and the operator flags, as one ExecStart value.
exec_line() {
  local ref word line=""
  ref="$(image_ref)" || return 1
  for word in "$ENTRYPOINT" --image "$ref" --runs-dir "$FM_SIM_RUNS_DIR" "${FM_SIM_AGENT_FLAGS[@]}"; do
    sim_safe_word "$word" || return 1
    line="${line:+$line }$word"
  done
  printf '%s\n' "$line"
}

# render TEMPLATE — the unit for this host.
render() {
  local exec
  exec="$(exec_line)" || return 1
  sim_render_unit "$1" "$FM_SIM_USER" "$PROJECT_DIR" "$exec" "$COMMS_ENV" \
    "fm-sim ${SIM_COMMIT}:$TEMPLATE_PATH"
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

# --- Reports ------------------------------------------------------------------

# Which bridge carries this host's runs. Reported, never changed: the card is
# `machine init`'s, and a workload switch moves what the bridge carries.
#
# A workstation is the one case with a second bridge to report. Its own runs
# Humble and cannot see the Jazzy sim nodes, so the sim topics cross only when
# fm-comms' sim bridge unit is running beside it. fm-setup does not own the
# workstation's fm-comms checkout (fm_ros2 does), so when that unit is not
# active the report names the command to run there and installs nothing.
bridge_report() {
  local workload checkout
  workload="$(fm_machine_workload 2>/dev/null || true)"
  case "$workload" in
    sim)
      fm_ok "card workload sim — fm-comms renders bridge-sim.json5" ;;
    workstation)
      if fm_has_cmd systemctl && systemctl is-active --quiet "$FM_COMMS_SIM_BRIDGE_UNIT" 2>/dev/null; then
        fm_ok "card workload workstation — $FM_COMMS_SIM_BRIDGE_UNIT is running, the Jazzy bridge that carries the sim topics"
      else
        checkout="$(fm_machine_get_opt workspace 2>/dev/null || true)"
        checkout="${checkout:-<workspace>}/fm-comms"
        fm_warn "card workload workstation — its Humble bridge (bridge-workstation.json5) cannot see the Jazzy sim nodes, and $FM_COMMS_SIM_BRIDGE_UNIT is not running"
        fm_info "the sim topics need the Jazzy sim bridge; install it from this workstation's fm-comms checkout at $FM_COMMS_TAG or later:"
        fm_info "  git -C $checkout fetch origin tag $FM_COMMS_TAG && git -C $checkout checkout --detach $FM_COMMS_TAG"
        fm_info "  $checkout/install.sh --role bridge-sim"
      fi ;;
    "")
      fm_warn "the card names no workload — no bridge carries this host's runs"
      fm_info "for a sim host: fm machine init --workload sim, then restart fm-zenoh-bridge" ;;
    *)
      fm_warn "card workload is '$workload' — fm-comms renders bridge-$workload.json5, which carries no sim topics"
      fm_info "for a sim host: fm machine init --workload sim, then restart fm-zenoh-bridge"
      fm_info "for a workstation: fm machine init --workload workstation, then add the Jazzy sim bridge (install.sh --role bridge-sim)" ;;
  esac
}

in_docker_group() { id -nG "$FM_SIM_USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; }

# Installed file equals TEXT.
same_file() { [ -f "$1" ] && [ "$(cat "$1")" = "$2" ]; }

have_commit() { read_src_git cat-file -e "$SIM_COMMIT^{commit}" 2>/dev/null; }

do_check() {
  bridge_report

  local rc=0 ref unit
  commit_pinned || rc=$?
  case "$rc" in
    0) fm_ok "fm-sim pinned at $SIM_COMMIT" ;;
    1) fm_warn "no fm-sim commit pinned (FM_SIM_COMMIT_DEFAULT) — no agent can be installed" ;;
  esac
  if [ "$rc" = 0 ] && have_commit; then
    fm_ok "$SRC_GIT holds the pinned commit"
  else
    fm_warn "$SRC_GIT does not hold the pinned commit"
  fi
  if [ "$rc" = 0 ] && [ "$(cat "$R$COMMIT_MARKER" 2>/dev/null)" = "$SIM_COMMIT" ]; then
    fm_ok "$PROJECT_DIR is the agent at the pinned commit"
  else
    fm_warn "$PROJECT_DIR is not the agent at the pinned commit"
  fi
  if [ -x "$R$UV_BIN" ] && [ "$(cat "$R$UV_MARKER" 2>/dev/null)" = "$(uv_sha 2>/dev/null)" ]; then
    fm_ok "$UV_BIN is the pinned uv $FM_UV_VERSION"
  else
    fm_warn "$UV_BIN is not the pinned uv $FM_UV_VERSION"
  fi
  if [ -x "$R$ENTRYPOINT" ]; then fm_ok "$ENTRYPOINT present"; else fm_warn "$ENTRYPOINT missing"; fi

  if getent passwd "$FM_SIM_USER" >/dev/null 2>&1; then
    fm_ok "account $FM_SIM_USER present"
    if in_docker_group; then
      fm_ok "$FM_SIM_USER is in the docker group (root-equivalent)"
    else
      fm_warn "$FM_SIM_USER is not in the docker group — the agent cannot start runs"
    fi
  else
    fm_warn "account $FM_SIM_USER missing"
  fi
  if [ -d "$R$FM_SIM_RUNS_DIR" ]; then fm_ok "$FM_SIM_RUNS_DIR present"; else fm_warn "$FM_SIM_RUNS_DIR missing"; fi

  # image_ref names what it refuses, so its message is left on stderr.
  if ref="$(image_ref)"; then
    private_image_note
    [ -n "$SIM_DIGEST" ] || fm_warn "no image digest pinned (${DIGEST_VAR}_DEFAULT) — the agent will not be enabled"
    if fm_has_docker && docker image inspect "$ref" >/dev/null 2>&1; then
      fm_ok "$ref pulled"
    else
      fm_warn "$ref not pulled"
    fi
  else
    fm_warn "the sim image is refused — install will fail until the value above is fixed"
  fi

  if [ "$rc" = 0 ] && have_commit \
     && unit="$(render "$(read_src_git show "$SIM_COMMIT:$TEMPLATE_PATH" 2>/dev/null)" 2>/dev/null)"; then
    if same_file "$R$UNIT_PATH" "$unit"; then
      fm_ok "$FM_SIM_UNIT installed and current"
    else
      fm_warn "$FM_SIM_UNIT missing or out of date — re-run: ./install.sh --${FM_ROLE:-workstation} --only sim"
    fi
  fi
  if fm_has_cmd systemctl && systemctl is-active --quiet "$FM_SIM_UNIT" 2>/dev/null; then
    fm_ok "$FM_SIM_UNIT active"
  else
    fm_warn "$FM_SIM_UNIT not active"
  fi
  return 0
}

# --- Install ------------------------------------------------------------------

dry_run_plan() {
  local ref rc=0 unit
  ref="$(image_ref)" || return 1
  commit_pinned || rc=$?
  [ "$rc" = 2 ] && return 1
  fm_log "dry run — nothing on this host changes"
  fm_info "would pull   $ref"
  private_image_note
  if [ "$rc" = 1 ]; then
    fm_info "no fm-sim commit pinned (FM_SIM_COMMIT_DEFAULT) — would install no agent"
    return 0
  fi
  fm_info "would fetch  $SIM_COMMIT from $SOURCE_URL into $SRC_GIT (as root)"
  fm_info "would copy   agent/ at that commit to $PROJECT_DIR (root:root, 755/644)"
  fm_info "would fetch  uv $FM_UV_VERSION to $UV_BIN, checked against sha256 $(uv_sha)"
  fm_info "would build  $VENV_DIR as root (uv sync --frozen --no-editable)"
  fm_info "would create system account $FM_SIM_USER (home $FM_SIM_HOME, no login)"
  fm_info "would create $FM_SIM_RUNS_DIR ($FM_SIM_USER:$FM_GROUP, 2770)"
  if have_commit; then
    unit="$(render "$(read_src_git show "$SIM_COMMIT:$TEMPLATE_PATH")")" || return 1
    fm_info "would write  $UNIT_PATH:"
    printf '%s\n' "$unit" | sed 's/^/        /'
  else
    fm_info "would write  $UNIT_PATH from the fetched commit's template"
  fi
  if [ -z "$SIM_DIGEST" ]; then
    fm_info "no image digest pinned — would write the unit, grant nothing, enable nothing"
  else
    fm_info "would ask    to add $FM_SIM_USER to the docker group (root-equivalent)"
    fm_info "would enable and start $FM_SIM_UNIT once $COMMS_ENV exists and the grant is given"
  fi
}

# A pull that fails is a warning: GHCR may want a login, and runs fail at `up`
# rather than here.
pull_image() {
  local ref="$1"
  if docker image inspect "$ref" >/dev/null 2>&1; then
    fm_ok "$ref already pulled"
    return 0
  fi
  [ -n "$SIM_DIGEST" ] || fm_warn "no image digest pinned (${DIGEST_VAR}_DEFAULT) — pulling the moving tag $SIM_IMAGE"
  private_image_note
  fm_log "pulling $ref"
  if docker pull "$ref"; then
    fm_ok "$ref pulled"
  else
    fm_warn "could not pull $ref — log in with: docker login ghcr.io, then re-run this step"
  fi
}

# Root fetches the pinned commit into its own bare repository.
fetch_source() {
  local got
  must "creating $FM_SIM_AGENT_ROOT" sudo install -d -o root -g root -m 0755 "$R$FM_SIM_AGENT_ROOT" || return 1
  if [ ! -f "$R$SRC_GIT/HEAD" ]; then
    must "creating $SRC_GIT" sudo "${GIT_ENV[@]}" git init --quiet --bare "$R$SRC_GIT" || return 1
  fi
  if ! src_git cat-file -e "$SIM_COMMIT^{commit}" 2>/dev/null; then
    fm_log "fetching fm-sim $SIM_COMMIT (as root)"
    must "fetching $SIM_COMMIT from $SOURCE_URL" src_git fetch --quiet --depth 1 "$SOURCE_URL" "$SIM_COMMIT" || return 1
  fi
  got="$(src_git rev-parse --verify --quiet "$SIM_COMMIT^{commit}")" || got=""
  if [ "$got" != "$SIM_COMMIT" ]; then
    fm_err "the fetched commit is '${got:-nothing}', not the pinned $SIM_COMMIT"
    return 1
  fi
  fm_ok "$SRC_GIT holds $SIM_COMMIT"
}

ensure_account() {
  if getent passwd "$FM_SIM_USER" >/dev/null 2>&1; then
    fm_ok "account $FM_SIM_USER present"
    return 0
  fi
  fm_log "creating system account $FM_SIM_USER"
  must "creating account $FM_SIM_USER" sudo useradd --system --user-group --create-home \
    --home-dir "$FM_SIM_HOME" --shell /usr/sbin/nologin "$FM_SIM_USER" || return 1
  fm_ok "account $FM_SIM_USER created"
}

# Copy agent/ out of the fetched commit into the root-owned tree. The marker is
# written last, so a copy that fails part-way is redone on the next run.
install_agent_tree() {
  local root="$R$FM_SIM_AGENT_ROOT" listing stage
  if [ "$(cat "$R$COMMIT_MARKER" 2>/dev/null)" = "$SIM_COMMIT" ] && [ -d "$R$PROJECT_DIR" ]; then
    fm_ok "$PROJECT_DIR already at $SIM_COMMIT"
    return 0
  fi
  listing="$(src_git ls-tree -r "$SIM_COMMIT" -- agent)" || { fm_err "could not list agent/ at $SIM_COMMIT"; return 1; }
  printf '%s\n' "$listing" | sim_tree_ok || { fm_err "agent/ at $SIM_COMMIT is refused — nothing extracted"; return 1; }

  stage="$(sudo mktemp -d "$root/.project.XXXXXX")" || { fm_err "creating a staging directory failed"; return 1; }
  if ! src_git archive --format=tar "$SIM_COMMIT" agent \
       | sudo tar -x --no-same-owner --no-same-permissions -C "$stage"; then
    sudo rm -rf "$stage"
    fm_err "extracting agent/ at $SIM_COMMIT failed"
    return 1
  fi
  if ! { must "handing $PROJECT_DIR to root" sudo chown -R root:root "$stage" \
      && must "setting directory modes" sudo find "$stage" -type d -exec chmod 0755 {} + \
      && must "setting file modes" sudo find "$stage" -type f -exec chmod 0644 {} + \
      && must "removing the old $PROJECT_DIR" sudo rm -rf "$R$PROJECT_DIR" \
      && must "moving the new $PROJECT_DIR into place" sudo mv "$stage/agent" "$R$PROJECT_DIR"; }; then
    sudo rm -rf "$stage"
    return 1
  fi
  sudo rmdir "$stage" 2>/dev/null || true
  printf '%s\n' "$SIM_COMMIT" | sudo tee "$R$COMMIT_MARKER" >/dev/null \
    || { fm_err "recording the installed commit failed"; return 1; }
  fm_ok "$PROJECT_DIR at $SIM_COMMIT (root:root, 755/644)"
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
  stage="$(sudo mktemp -d "$R$FM_SIM_AGENT_ROOT/.uv.XXXXXX")" || { fm_err "creating a staging directory failed"; return 1; }
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

# Build the agent's venv as root, from the root-owned project, with nothing
# inherited: no uv config file, no index override, no PATH beyond the system's.
# Non-editable, so the venv holds the agent and the service needs no uv.
build_venv() {
  must "creating $FM_SIM_UV_CACHE" sudo install -d -o root -g root -m 0700 "$R$FM_SIM_UV_CACHE" || return 1
  fm_log "building $VENV_DIR (as root, from $PROJECT_DIR)"
  must "building $VENV_DIR" sudo env -i PATH=/usr/bin:/bin HOME=/nonexistent UV_NO_CONFIG=1 \
    "UV_PROJECT_ENVIRONMENT=$R$VENV_DIR" "UV_CACHE_DIR=$R$FM_SIM_UV_CACHE" \
    "UV_PYTHON=$FM_CLI_PYTHON" UV_PYTHON_DOWNLOADS=never \
    "$R$UV_BIN" sync --quiet --frozen --no-dev --no-editable --directory "$R$PROJECT_DIR" || return 1
  [ -x "$R$ENTRYPOINT" ] || { fm_err "$ENTRYPOINT missing after the build"; return 1; }
  must "setting venv modes" sudo chmod -R u+rwX,go+rX,go-w "$R$VENV_DIR" || return 1
  fm_ok "$VENV_DIR built; the service starts $ENTRYPOINT"
}

ensure_runs_dir() {
  must "creating $FM_SIM_RUNS_DIR" sudo install -d -o "$FM_SIM_USER" -g "$FM_GROUP" -m 2770 "$R$FM_SIM_RUNS_DIR" || return 1
  fm_ok "$FM_SIM_RUNS_DIR ready ($FM_SIM_USER:$FM_GROUP, 2770)"
}

# install_unit TEXT — 0 when the unit changed, 3 when it was already current,
# 1 on a failure.
install_unit() {
  local text="$1" path="$R$UNIT_PATH" stage rc=0
  if same_file "$path" "$text"; then
    fm_ok "$FM_SIM_UNIT current"
    return 3
  fi
  # Staged in a root-owned directory, never a file the invoking account owns.
  stage="$(sudo mktemp -d "$R$FM_SIM_AGENT_ROOT/.unit.XXXXXX")" || { fm_err "creating a staging directory failed"; return 1; }
  if ! printf '%s\n' "$text" | sudo tee "$stage/unit" >/dev/null; then
    fm_err "staging $UNIT_PATH failed"
    rc=1
  elif ! { must "creating $(dirname "$UNIT_PATH")" sudo install -d -m 0755 "$(dirname "$path")" \
      && must "writing $UNIT_PATH" sudo install -o root -g root -m 0644 "$stage/unit" "$path" \
      && must "reloading systemd" sudo systemctl daemon-reload; }; then
    rc=1
  fi
  sudo rm -rf "$stage"
  [ "$rc" = 0 ] || return 1
  fm_ok "wrote $UNIT_PATH"
}

# The docker grant, asked for. 0 when the account holds it, 2 when declined,
# 1 on a failure.
#
# The sim-cloud role run unattended is the one exception, and grants it without
# asking: that is its stack's bootstrap, on a single-purpose instance launched
# to serve sim runs, where an agent without the grant serves nothing and
# choosing the role is the decision to grant it. Run by a person, it asks.
grant_docker() {
  if in_docker_group; then
    fm_ok "$FM_SIM_USER already in the docker group"
    return 0
  fi
  fm_warn "the docker group is equivalent to root — $FM_SIM_USER could mount the host filesystem into a container"
  local unattended_cloud=0
  if [ "${FM_ROLE:-}" = sim-cloud ] && [ "${NONINTERACTIVE:-0}" = 1 ]; then
    unattended_cloud=1
    fm_info "sim-cloud role, unattended: granting without a prompt"
  fi
  if [ "$unattended_cloud" = 1 ] || fm_confirm "Add $FM_SIM_USER to the docker group so the sim agent can start runs?"; then
    must "adding $FM_SIM_USER to the docker group" sudo usermod -aG docker "$FM_SIM_USER" || return 1
    fm_ok "$FM_SIM_USER added to the docker group"
    return 0
  fi
  fm_skip "docker grant declined — $FM_SIM_UNIT written but not enabled; re-run interactively to grant it"
  return 2
}

do_install() {
  if [ "${1:-}" = "--dry-run" ]; then
    bridge_report
    dry_run_plan
    return
  fi

  local ref rc=0 template unit changed=1
  ref="$(image_ref)" || return 1
  exec_line >/dev/null || return 1
  commit_pinned || rc=$?
  [ "$rc" = 2 ] && return 1

  bridge_report
  fm_has_docker || { fm_err "docker is not reachable — run the docker step first"; return 1; }
  fm_has_cmd systemctl || { fm_err "no systemctl — the sim agent is a systemd service"; return 1; }

  if ghcr_pull_needed && ! docker image inspect "$ref" >/dev/null 2>&1; then
    ghcr_pull "$ref" || return 1
  else
    pull_image "$ref"
  fi
  if [ "$rc" = 1 ]; then
    fm_warn "no fm-sim commit pinned (FM_SIM_COMMIT_DEFAULT) — no agent installed"
    return 0
  fi

  fetch_source || return 1
  template="$(src_git show "$SIM_COMMIT:$TEMPLATE_PATH")" \
    || { fm_err "fm-sim $SIM_COMMIT has no $TEMPLATE_PATH"; return 1; }
  unit="$(render "$template")" || return 1

  ensure_account || return 1
  install_agent_tree || return 1
  install_uv || return 1
  build_venv || return 1
  ensure_runs_dir || return 1
  rc=0
  install_unit "$unit" || rc=$?
  case "$rc" in
    0) changed=1 ;;
    3) changed=0 ;;
    *) return 1 ;;
  esac

  if [ -z "$SIM_DIGEST" ]; then
    fm_warn "no image digest pinned (${DIGEST_VAR}_DEFAULT) — $FM_SIM_UNIT written, not enabled, no docker grant"
    return 0
  fi
  rc=0
  grant_docker || rc=$?
  case "$rc" in
    0) ;;
    2) return 0 ;;
    *) return 1 ;;
  esac
  if [ ! -f "$R$COMMS_ENV" ]; then
    fm_skip "$COMMS_ENV missing — install fm-comms through fm_ros2, then re-run: ./install.sh --${FM_ROLE:-workstation} --only sim"
    return 0
  fi
  must "enabling $FM_SIM_UNIT" sudo systemctl enable "$FM_SIM_UNIT" || return 1
  if [ "$changed" = 1 ]; then
    must "restarting $FM_SIM_UNIT" sudo systemctl restart "$FM_SIM_UNIT" || return 1
  else
    must "starting $FM_SIM_UNIT" sudo systemctl start "$FM_SIM_UNIT" || return 1
  fi
  fm_ok "$FM_SIM_UNIT enabled and running — serves fm/sim/$(fm_machine_namespace)/*"
}

# remove_tree PATH — rm -rf one of the step's own trees, named exactly.
remove_tree() {
  case "$1" in
    /var/lib/fm-sim | /opt/fm-sim-agent | /var/cache/fm-sim-agent) ;;
    *) fm_warn "not removing $1 — not one of the sim step's trees; remove it by hand"; return 0 ;;
  esac
  if [ -d "$R$1" ]; then
    must "removing $1" sudo rm -rf "$R$1" || return 1
    fm_ok "$1 removed"
  fi
}

do_uninstall() {
  if [ -f "$R$UNIT_PATH" ]; then
    fm_log "removing $FM_SIM_UNIT"
    must "disabling $FM_SIM_UNIT" sudo systemctl disable --now "$FM_SIM_UNIT" || return 1
    must "removing $UNIT_PATH" sudo rm -f "$R$UNIT_PATH" || return 1
    must "reloading systemd" sudo systemctl daemon-reload || return 1
    fm_ok "$FM_SIM_UNIT removed"
  else
    fm_skip "$FM_SIM_UNIT not installed"
  fi

  local ref
  if ref="$(image_ref 2>/dev/null)" && fm_has_docker && docker image inspect "$ref" >/dev/null 2>&1; then
    must "removing $ref" docker image rm "$ref" >/dev/null || return 1
    fm_ok "$ref removed"
  else
    fm_skip "fm-sim image not present"
  fi

  if getent passwd "$FM_SIM_USER" >/dev/null 2>&1; then
    must "removing account $FM_SIM_USER" sudo userdel "$FM_SIM_USER" || return 1
    fm_ok "account $FM_SIM_USER removed"
  fi
  remove_tree "$FM_SIM_AGENT_ROOT" || return 1
  remove_tree "$FM_SIM_UV_CACHE" || return 1
  remove_tree "$FM_SIM_HOME" || return 1

  fm_warn "$FM_SIM_RUNS_DIR left in place — run summaries and MCAPs are data"
  return 0
}

fm_dispatch "$@"
