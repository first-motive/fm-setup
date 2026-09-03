#!/usr/bin/env bash
#
# onboard — set up your own account on a machine somebody else provisioned.
#
#   fm setup-onboard
#
# One command, with no checkout of your own. The machine's workspace lives at
# /opt/fm where everyone can read it, and the fm CLI is on every account's PATH
# from /usr/local/bin, so the CLI mounts this verb from the machine's own
# fm-setup and a newcomer never clones anything to get started.
#
# That verb is reachable exactly once, which is worth knowing before it puzzles
# somebody. The CLI mounts a repo's verbs from the workspace it resolves; for an
# account with nothing set that is the card's, and `fm setup-onboard` is there.
# This script then writes FM_HOME, and from the next shell onwards the resolved
# workspace is the person's own — which holds no fm-setup, and needs none. The
# verb is gone, and every re-run this script prints names the machine's checkout
# directly instead. `./run.sh onboard` is the same script by another road.
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
#   ~/fm               your workspace, with FM_HOME in ~/.fm-profile. The card
#                      names the machine's workspace, which is shared; yours is
#                      your own, and FM_HOME outranks the card for that reason
#   ~/AGENTS.md        a personal SSH first-read, printed once at login
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
BASHRC="$HOME/.bashrc"
# The account that owns the machine's workspace is the machine, not a person on
# it, and a personal workspace is the wrong thing to hand it: the card's
# workspace is where its checkouts, its services and its data root already are.
# Giving it ~/fm instead pointed every verb at an empty directory — on fm-ws-01,
# after the checkouts moved under the card's workspace, `fm doctor` reported
# every repo "not cloned" while all of them sat one directory away.
#
# Anyone else onboarding on the same machine still gets their own tree, which is
# the case this script was written for.
service_account_workspace() {
  local workspace owner
  workspace="$(FM_HOME='' fm_machine_workspace)" || return 1
  [ -d "$workspace" ] || return 1
  owner="$(stat -c '%U' "$workspace" 2>/dev/null)" || return 1
  [ "$owner" = "$(id -un)" ] || return 1
  printf '%s\n' "$workspace"
}

if [ -n "${FM_HOME:-}" ]; then
  WORKSPACE="$FM_HOME"
elif WORKSPACE="$(service_account_workspace)"; then
  :
else
  WORKSPACE="$HOME/fm"
fi
FM_AI_DIR="$WORKSPACE/fm-ai"

# One file holds what this script adds to a shell, and the shell files only
# source it.
#
# Writing the exports straight into ~/.profile was enough for a login shell and
# for nothing else: bash reads ~/.profile when it is a login shell and ~/.bashrc
# when it is interactive without being one, which is every tmux pane, every
# `bash` subshell, and every VS Code Remote terminal. In those, PATH lacked
# ~/.local/bin — `claude: command not found` on a machine where Claude Code was
# installed — and FM_HOME was unset, so `fm` fell back to the card and answered
# about the machine's checkouts rather than the person's own.
#
# A file of its own rather than two copies of the exports: one place to change,
# and a re-run rewrites it wholesale instead of appending to a list nobody
# prunes.
SHELL_ENV="$HOME/.fm-profile"
SHELL_ENV_LINE=". \"\$HOME/.fm-profile\""

usage() {
  cat <<'EOF'
onboard — set up your own account on a First Motive machine

Usage: fm setup-onboard
       fm setup-onboard --help

Installs uv, the fm CLI, and Claude Code into your home directory, creates your
workspace, installs the SSH first-read, and clones the org skill set if you are
already signed in to GitHub. No sudo, nothing outside your home directory. Safe
to run twice.
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
  fm_ok "$LOCAL_BIN on PATH"
}

# --- Workspace --------------------------------------------------------------

# A workspace path this script is willing to write into ~/.fm-profile.
#
# Absolute is the card's own rule, so it comes from the card's validator rather
# than a second copy of it. The character check is this script's addition: the
# path is written into that file as `export FM_HOME="…"`, and inside double
# quotes a `$(…)` or a backtick in the value would be code every future shell
# runs. The value comes from the caller's own environment, which makes it
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
# host, and what it names is the machine's shared workspace at /opt/fm — the
# right answer for a service and the wrong one for a person, who wants their own
# branches under their own home. FM_HOME is per person, and lib.sh reads it
# before the card for exactly this case.
ensure_workspace() {
  valid_workspace "$WORKSPACE" || return 1
  mkdir -p "$WORKSPACE"
  export FM_HOME="$WORKSPACE"
  fm_ok "workspace $WORKSPACE"
}

# --- What a shell inherits --------------------------------------------------

# Write ~/.fm-profile, then make both shell files source it.
#
# The PATH entry is guarded at runtime rather than written once, because both
# files can run in a single shell — a login bash reads ~/.profile, which on
# Ubuntu sources ~/.bashrc — and an unguarded prepend would stack a duplicate
# entry on every nesting.
#
# The earlier version's two raw exports are stripped from ~/.profile first, so
# an account onboarded before this change converges instead of carrying both.
ensure_shell_env() {
  cat >"$SHELL_ENV" <<EOF
# Managed by fm-setup — written by \`fm setup-onboard\`, replaced on every run.
# Put your own settings in ~/.profile or ~/.bashrc instead; edits here are lost.

case ":\$PATH:" in
  *":\$HOME/.local/bin:"*) ;;
  *) PATH="\$HOME/.local/bin:\$PATH" ;;
esac
export PATH
export FM_HOME="$WORKSPACE"
EOF

  # shellcheck disable=SC2016  # the literal line the earlier version wrote
  fm_strip_line "$PROFILE" 'export PATH="$HOME/.local/bin:$PATH"'
  # By shape, not by text: a run with a different workspace than last time would
  # never match its own earlier line, and both exports would survive.
  fm_strip_matching "$PROFILE" '^export FM_HOME='

  fm_ensure_line "$PROFILE" "$SHELL_ENV_LINE"
  fm_ensure_line "$BASHRC"  "$SHELL_ENV_LINE"

  fm_ok "shell environment in $SHELL_ENV, sourced from ~/.profile and ~/.bashrc"
}

# --- SSH first-read --------------------------------------------------------

# A login shell shows the machine router before the prompt, matching the Bongi
# host's first-read without adding output to `ssh host command`, local shells,
# tmux panes, or VS Code Remote terminals. The installer preserves a personal
# AGENTS.md and refuses an occupied hook path.
install_ssh_first_read() {
  bash "$FM_ROOT/scripts/internal/install-ssh-first-read.sh"
}

# --- uv and the fm CLI ------------------------------------------------------

# Delegated, not repeated. The fm-cli step installs uv from a pinned installer
# and the CLI from a pinned tag, and it is already per-user — it uses no sudo
# and uv installs into the invoking account's home. A second copy of that logic
# here would be the copy that drifts.
#
# Run non-interactively, which is not about being unattended: that step also
# offers to install the machine-wide CLI at /usr/local/bin/fm, and NONINTERACTIVE
# is how its fm_confirm declines. Onboarding is somebody setting up their own
# account, usually without sudo at all, and a password prompt for an install they
# cannot make and did not ask for is the wrong end of the one-command promise.
# The administrator makes that one, through install.sh.
install_fm_cli() {
  fm_log "uv and the fm CLI"
  NONINTERACTIVE=1 bash "$FM_ROOT/scripts/steps/15-fm-cli.sh" install
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
    fm_info "install it, sign in, then run this again: $FM_ROOT/run.sh onboard"
    return 0
  fi

  if ! gh auth status >/dev/null 2>&1; then
    fm_warn "not signed in to GitHub — skipping fm-ai"
    fm_info "sign in, then run this again:"
    fm_info "  gh auth login"
    fm_info "  $FM_ROOT/run.sh onboard"
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
    fm_warn "fm-ai's installer failed — re-run $FM_ROOT/run.sh onboard once it is fixed"
  fi
  return 0
}

# --- Signing in -------------------------------------------------------------

# The last four things are credentials, and every one of them is personal and
# interactive. A script cannot do them for anybody, so it says so and stops.
#
# The re-run is spelled as a path rather than as `fm setup-onboard`, because by
# the time anybody reads this the verb has stopped existing for them. The CLI
# mounts a repo's verbs from the workspace it resolves, and this run has just
# written FM_HOME — which points at the person's own workspace, where there is
# no fm-setup checkout and no reason for one. The machine's checkout is readable
# by everybody, so calling it directly always works. fm-tools falling back to
# the card's workspace for a repo the person does not have would remove the
# seam; until then this line is honest and the one-liner would not be.
checklist() {
  echo
  fm_log "sign in as yourself"
  fm_info "1. claude          then /login"
  fm_info "2. gh auth login   then re-run $FM_ROOT/run.sh onboard for the org skills"
  fm_info "3. git config --global user.name \"Your Name\""
  fm_info "4. git config --global user.email you@ubundi.co.za"
  echo
  fm_info "open a new shell (or: . $SHELL_ENV) so PATH and FM_HOME take effect"
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
  ensure_shell_env
  install_ssh_first_read
  install_fm_cli
  install_claude
  install_fm_ai
  checklist
}

main "$@"
