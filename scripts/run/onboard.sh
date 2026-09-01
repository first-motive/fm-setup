#!/usr/bin/env bash
#
# onboard — set up your own account on a machine somebody else provisioned.
#
#   ./run.sh onboard
#
# `add-user` is the administrator's half: an account, the fm group, /data. This
# is the other half, and the person it belongs to runs it themselves. Nothing
# here uses sudo, and nothing here leaves the home directory it runs in — which
# is why it needs no step, no manifest entry, and no administrator present.
#
# What it lays down:
#
#   ~/.local/bin       on PATH, where uv and Claude Code both install
#   uv + the fm CLI    delegated to the fm-cli step, not repeated here
#   claude             Claude Code, unpinned — see below
#   ~/fm               your workspace, with FM_HOME in ~/.profile so every
#                      tool resolves it instead of the machine card's, which
#                      names the administrator's home and is unreadable to you
#   ~/fm/fm-ai         the org skill set, when GitHub auth is already in place
#
# Claude Code is deliberately not pinned. It updates itself in place, so a
# version written here would describe the installer's day and nothing after it.
# The fm CLI is pinned, because two machines provisioned months apart should
# agree about it; that pin lives in the manifest, with the step that applies it.
#
# Idempotent by contract, like a step: a second run finds every piece in place
# and changes nothing. The GitHub half is the reason that matters — it is the
# one piece that cannot complete before the person has signed in, so an
# unauthenticated run prints what to do and exits 0, and the re-run after
# `gh auth login` converges.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$_here/../.." && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$FM_ROOT/lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$FM_ROOT/scripts/manifest.sh"

LOCAL_BIN="$HOME/.local/bin"
PROFILE="$HOME/.profile"
WORKSPACE="${FM_HOME:-$HOME/fm}"
FM_AI_DIR="$WORKSPACE/fm-ai"

usage() {
  cat <<'EOF'
onboard — set up your own account on a First Motive machine

Usage: ./run.sh onboard
       ./run.sh onboard --help

Installs uv, the fm CLI, and Claude Code into your home directory, creates your
workspace, and clones the org skill set if you are already signed in to GitHub.
No sudo, nothing outside your home directory. Safe to run twice.
EOF
}

# Refuse to run as the machine's administrator by accident. Onboarding writes
# into the invoking account's home, and the whole point is that it is the
# person's own — running it under sudo would put root's files in root's home
# and leave the person with nothing.
refuse_root() {
  [ "$(id -u)" -ne 0 ] || {
    fm_err "onboard sets up your own account — run it as yourself, without sudo"
    return 1
  }
}

# --- PATH -------------------------------------------------------------------

# ~/.local/bin is where uv and Claude Code both land. Ubuntu's stock ~/.profile
# adds it, but only when the directory already exists at login — so a fresh
# account that installs into it during this run still has no PATH entry until
# the next login, and every command below would be "not found" in the meantime.
# Creating it first and exporting it here covers both halves.
ensure_local_bin() {
  mkdir -p "$LOCAL_BIN"
  case ":$PATH:" in
    *":$LOCAL_BIN:"*) ;;
    *) PATH="$LOCAL_BIN:$PATH"; export PATH ;;
  esac
  # shellcheck disable=SC2016  # $HOME is written into ~/.profile, not expanded here
  fm_ensure_line "$PROFILE" 'export PATH="$HOME/.local/bin:$PATH"'
  fm_ok "$LOCAL_BIN on PATH"
}

# --- Workspace --------------------------------------------------------------

# A workspace path this script is willing to write into ~/.profile.
#
# Absolute is the card's own rule, so it comes from the card's validator rather
# than a second copy of it. The character check is this script's addition: the
# path is written into a profile as `export FM_HOME="…"`, and inside double
# quotes a `$(…)` or a backtick in the value would be code every future login
# shell runs. The value comes from the caller's own environment, which makes it
# their own foot at worst — and a mistyped path that silently becomes a command
# is worth refusing whoever typed it.
valid_workspace() { # path
  fm_machine_valid_workspace "$1" || return 1
  case "$1" in
    *'$'* | *'`'* | *'"'* | *"'"* | *[\\]*)
      fm_err "invalid FM_HOME: '$1' (no quotes, backslashes, backticks, or \$)"
      return 1 ;;
  esac
}

# FM_HOME rather than a machine card edit: the card is one file for the whole
# host and says where the administrator's checkouts are, at a mode nobody else
# can read. FM_HOME is per person, and lib.sh reads it before the card for
# exactly this case.
ensure_workspace() {
  valid_workspace "$WORKSPACE" || return 1
  mkdir -p "$WORKSPACE"
  fm_ensure_line "$PROFILE" "export FM_HOME=\"$WORKSPACE\""
  export FM_HOME="$WORKSPACE"
  fm_ok "workspace $WORKSPACE (FM_HOME in $PROFILE)"
}

# --- uv and the fm CLI ------------------------------------------------------

# Delegated, not repeated. The fm-cli step installs uv from a pinned installer
# and the CLI from a pinned tag, and it is already per-user — it uses no sudo
# and uv installs into the invoking account's home. A second copy of that logic
# here would be the copy that drifts.
install_fm_cli() {
  fm_log "uv and the fm CLI"
  bash "$FM_ROOT/scripts/steps/15-fm-cli.sh" install
}

# --- Claude Code ------------------------------------------------------------

install_claude() {
  if fm_has_cmd claude; then
    fm_ok "claude $(claude --version 2>/dev/null | awk '{print $1}')"
    return 0
  fi

  fm_log "installing Claude Code"
  # Trust boundary, stated plainly because this is a piped installer, the same
  # way the uv step states its own: TLS and Anthropic are the anchor. There is
  # no checksum to pin against — the installer fetches whatever the current
  # release is, which is the same reason the version is not pinned.
  if curl -fsSL https://claude.ai/install.sh | bash; then
    fm_ok "Claude Code installed"
  else
    # Not fatal: everything else this script sets up is still worth having, and
    # the checklist at the end names the retry.
    fm_warn "the Claude Code installer failed — retry with: curl -fsSL https://claude.ai/install.sh | bash"
  fi
  return 0
}

# --- The org skill set ------------------------------------------------------

# fm-ai holds the shared skills, agents, and hooks, and its own install.sh
# links them into ~/.claude. Cloning it needs GitHub auth this script cannot
# supply: the credential is the person's, and `gh auth login` is interactive.
#
# So this half is gated rather than attempted. Unauthenticated, it prints the
# two commands and returns 0 — the run is not a failure, it is incomplete, and
# the re-run after signing in finishes it.
install_fm_ai() {
  fm_log "the org skill set"

  if ! fm_has_cmd gh; then
    fm_warn "gh not installed — skipping fm-ai"
    fm_info "install it, sign in, then run this again: ./run.sh onboard"
    return 0
  fi

  if ! gh auth status >/dev/null 2>&1; then
    fm_warn "not signed in to GitHub — skipping fm-ai"
    fm_info "sign in, then run this again:"
    fm_info "  gh auth login"
    fm_info "  ./run.sh onboard"
    return 0
  fi

  if [ -d "$FM_AI_DIR/.git" ]; then
    fm_ok "fm-ai already cloned at $FM_AI_DIR"
  else
    fm_log "cloning fm-ai into $FM_AI_DIR"
    gh repo clone "$FM_AI_REPO" "$FM_AI_DIR" || {
      fm_warn "could not clone $FM_AI_REPO — skipping its install"
      return 0
    }
  fi

  # fm-ai's installer is idempotent and per-user by design; it is the same
  # thing anyone runs on their laptop.
  if [ ! -x "$FM_AI_DIR/install.sh" ]; then
    fm_warn "$FM_AI_DIR/install.sh missing — nothing installed"
  elif bash "$FM_AI_DIR/install.sh"; then
    fm_ok "org skills installed"
  else
    # Non-fatal for the same reason the GitHub gate is: the rest of this run is
    # still worth having, and a re-run is what finishes an incomplete one. An
    # abort here would leave the sign-in checklist unprinted.
    fm_warn "fm-ai's installer failed — re-run ./run.sh onboard once it is fixed"
  fi
  return 0
}

# --- Signing in -------------------------------------------------------------

# The last four things are credentials, and every one of them is personal and
# interactive. A script cannot do them for anybody, so it says so and stops.
checklist() {
  echo
  fm_log "sign in as yourself"
  fm_info "1. claude          then /login"
  fm_info "2. gh auth login   then re-run ./run.sh onboard for the org skills"
  fm_info "3. git config --global user.name \"Your Name\""
  fm_info "4. git config --global user.email you@ubundi.co.za"
  echo
  fm_info "open a new shell (or: . $PROFILE) so PATH and FM_HOME take effect"
}

main() {
  case "${1:-}" in
    -h|--help) usage; return 0 ;;
    "") ;;
    *) fm_err "unknown option: $1"; usage; return 1 ;;
  esac

  fm_require_linux
  refuse_root
  fm_log "onboarding $(id -un) onto $(hostname)"
  echo

  ensure_local_bin
  ensure_workspace
  install_fm_cli
  install_claude
  install_fm_ai
  checklist
}

main "$@"
