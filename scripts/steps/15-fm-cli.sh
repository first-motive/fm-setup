#!/usr/bin/env bash
#
# fm-cli — the cross-repo CLI (fm list/status/doctor/update/setup).
#
# A First Motive machine carries several fm_ros2 checkouts, one per role, and
# telling them apart by directory name gets old quickly. `fm status` reads all of
# them at once, and `fm update` brings them forward without anyone remembering
# which remote each is on.
#
# Installed as an isolated uv tool from a pinned git tag — the same thing
# fm-tools' own install.sh does, so a machine provisioned here and a laptop set
# up by hand end up with the same CLI. This step does not duplicate that logic;
# it only makes sure uv exists first, which fm-tools requires but does not
# install.
#
# Installed twice, deliberately.
#
# Once under the invoking account's home, which is where uv puts a tool and what
# `fm setup-onboard` gives a person. Once for the machine, root-owned in
# /opt/fm-tools with the command at /usr/local/bin/fm — because a newcomer with
# an empty home has nothing on PATH and nothing to run, and the CLI is how they
# onboard. It cannot be the thing that waits until they have onboarded.
#
# The machine-wide copy is its own install rather than a link to somebody's,
# for a reason worth stating once: a uv tool binary is a symlink into
# ~/.local/share/uv, and its venv names an interpreter uv chose — under sudo,
# one in /root at mode 700. A link to it is readable, executable, and still
# unrunnable by every account but the owner's.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$_here/../../lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$_here/../manifest.sh"

fm_require_linux

# The exact spec uv is asked to install. One place builds it so check, install,
# and the dry run all talk about the same thing.
fm_tools_spec() {
  printf 'fm-tools @ git+https://github.com/%s@%s\n' "$FM_TOOLS_REPO" "$FM_TOOLS_VERSION"
}

# uv lands in ~/.local/bin, which is on PATH only after `uv tool update-shell`
# has run once and the shell has been restarted. During provisioning neither has
# happened yet, so look there directly rather than trusting PATH.
uv_bin() {
  if fm_has_cmd uv; then command -v uv; return 0; fi
  [ -x "$HOME/.local/bin/uv" ] && printf '%s\n' "$HOME/.local/bin/uv" && return 0
  return 1
}

# The machine-wide command, and the tool tree behind it.
FM_MACHINE_FM="$FM_CLI_BIN_DIR/fm"

# Return success when the machine-wide fm is the one this step installs, rather
# than something else that happens to answer to the same name. Resolved before
# comparing, because it is a symlink uv writes into the bin directory.
machine_fm_is_ours() {
  case "$(readlink -f "$FM_MACHINE_FM" 2>/dev/null)" in
    "$FM_CLI_TOOL_DIR"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Refuse a path that anyone but its owner can write.
#
# Used on what is about to be executed as root. Group- and world-write are both
# refused: on a machine where the whole team shares one group, group-write is
# the shape that actually occurs, and it hands every member the root the
# administrator holds.
refuse_writable_by_others() { # path
  local mode
  mode="$(stat -c '%a' "$1" 2>/dev/null)" || return 0
  # 0022 is the group-write and other-write bits, and nothing else.
  if [ $(( 8#$mode & 0022 )) -ne 0 ]; then
    fm_warn "$1 is mode $mode — not running it as root while others can write it"
    fm_info "its owner makes it safe with: chmod go-w $1"
    return 1
  fi
}

do_check() {
  check_user_install
  check_machine_install
  return 0
}

check_machine_install() {
  if ! [ -e "$FM_MACHINE_FM" ]; then
    fm_warn "no $FM_MACHINE_FM — an account that has installed nothing has no fm on PATH"
    return 0
  fi
  if ! machine_fm_is_ours; then
    fm_warn "$FM_MACHINE_FM resolves to $(readlink -f "$FM_MACHINE_FM"), outside $FM_CLI_TOOL_DIR"
    return 0
  fi
  fm_ok "$FM_MACHINE_FM -> $(readlink -f "$FM_MACHINE_FM")"

  # The one failure that looks like success from the administrator's own shell:
  # every account can see the command, and only the account that installed it
  # can run it. Reported by asking the question that matters — is it executable
  # by others — rather than by reading modes back one directory at a time.
  if [ ! -r "$FM_MACHINE_FM" ]; then
    fm_warn "$FM_MACHINE_FM is not readable — the rest of the team cannot run it"
  fi
}

check_user_install() {
  local uv fm_path
  if uv="$(uv_bin)"; then
    fm_ok "uv $("$uv" --version 2>/dev/null | awk '{print $2}')"
  else
    fm_warn "uv missing"
    return 0
  fi

  if fm_path="$(command -v fm 2>/dev/null)"; then
    fm_ok "fm on PATH ($fm_path)"
  elif [ -x "$HOME/.local/bin/fm" ]; then
    fm_warn "fm installed but not on PATH — run: uv tool update-shell, then restart the shell"
  else
    fm_warn "fm not installed"
    return 0
  fi

  # The installed tag, not the wheel version: they track each other, and the tag
  # is what this manifest pins.
  if "$uv" tool list 2>/dev/null | grep -q '^fm-tools'; then
    fm_info "pinned: $(fm_tools_spec)"
  fi
  return 0
}

install_uv() {
  local script rc=0
  fm_log "installing uv $FM_UV_VERSION"

  script="$(mktemp)"

  # One place creates the temp file and one place removes it, matching
  # 40-ros2.sh. Not a `trap … RETURN`: that trap is not scoped to the function
  # that sets it, so it fires again when the caller returns and aborts a run
  # that had already succeeded — the bug 40-ros2.sh documents.
  _install_uv_inner "$script" || rc=$?
  rm -f "$script"
  [ "$rc" -eq 0 ] || return "$rc"

  fm_ok "uv installed"
}

# Fetch, optionally verify, and run Astral's installer. Split out so install_uv
# owns the temp file's whole life.
#
# Trust boundary, stated here as well as in the manifest because this is the
# line that runs the code: the URL carries the pinned version rather than
# "latest", apt-style signing does not apply to a shell script, and so TLS plus
# Astral are the anchor unless FM_UV_INSTALLER_SHA256 is set.
_install_uv_inner() {
  local script="$1"

  curl -fsSL "https://astral.sh/uv/${FM_UV_VERSION}/install.sh" -o "$script" \
    || { fm_err "could not fetch the uv installer"; return 1; }

  if [ -n "${FM_UV_INSTALLER_SHA256:-}" ]; then
    fm_verify_checksum "$script" "$FM_UV_INSTALLER_SHA256" || return 1
    fm_ok "uv installer checksum verified"
  else
    # Not fatal, and said out loud: silence here would read as "verified".
    fm_warn "no uv installer checksum pinned — trusting TLS (set FM_UV_INSTALLER_SHA256)"
  fi

  sh "$script" || { fm_err "the uv installer failed"; return 1; }
}

do_install() {
  local uv spec
  # An existing uv is left at whatever version it is, even when that differs
  # from the pin. FM_UV_VERSION decides what a machine with no uv gets; it is
  # not a demand that every machine converge, because uv is a general tool other
  # work on the box may depend on and this step did not necessarily install it.
  # What must be reproducible is the CLI, and `uv tool install --force` below
  # pins that outright.
  uv_bin >/dev/null || install_uv
  uv="$(uv_bin)" || { fm_err "uv still not found after install"; return 1; }

  spec="$(fm_tools_spec)"
  fm_log "installing the fm CLI ($FM_TOOLS_VERSION)"
  # --force so a re-run moves an existing install to the pinned tag rather than
  # reporting "already installed" and leaving an older CLI in place.
  "$uv" tool install --force "$spec"

  # uv owns its bin directory, so let uv wire the PATH rather than editing a
  # profile here. Idempotent, and it is what fm-tools tells a human to run.
  if [ "${FM_NO_MODIFY_PATH:-0}" = "1" ]; then
    fm_info "FM_NO_MODIFY_PATH set — not running 'uv tool update-shell'"
  else
    "$uv" tool update-shell >/dev/null 2>&1 || true
  fi

  if fm_has_cmd fm; then
    fm_ok "fm ready — try: fm status"
  else
    fm_ok "fm installed"
    fm_info "not on PATH in this shell yet; open a new one, then: fm status"
  fi

  install_machine_wide "$uv"
}

# Install the CLI once for the whole machine, root-owned and outside every home.
#
# Its own install rather than a link to the one above. A link into a home is a
# command the team cannot run: the home is mode 750, the tool binary is a
# symlink into ~/.local/share/uv, and the venv's shebang names an interpreter
# that uv had put under the installing account's home as well — three private
# directories deep, each of which turns `fm` into "Permission denied" for
# everybody else while looking perfectly healthy to its owner. Nothing here
# resolves through a home at all.
#
# Every obstacle is a skip rather than a failure: the per-user install above has
# already succeeded, and an administrator who cannot write /usr/local/bin still
# has a working CLI. A step that went red here would report a machine as
# unprovisioned over a convenience.
install_machine_wide() { # uv
  local uv="$1"

  if [ -e "$FM_MACHINE_FM" ] && ! machine_fm_is_ours; then
    # Something else owns this name. Replacing it would change what every
    # account on the box runs, which is not this step's call to make.
    fm_warn "$FM_MACHINE_FM resolves to $(readlink -f "$FM_MACHINE_FM"), outside $FM_CLI_TOOL_DIR — leaving it"
    return 0
  fi

  if ! fm_has_cmd sudo; then
    fm_skip "no sudo here — no $FM_MACHINE_FM, so only this account has fm on PATH"
    return 0
  fi

  # Writing into /usr/local/bin decides which CLI the whole machine runs, so it
  # is asked for rather than assumed, and an unattended run declines and says so.
  fm_warn "$FM_MACHINE_FM is the fm every account on this box runs, upgraded only by an administrator"
  if ! fm_confirm "Install the pinned CLI to $FM_CLI_TOOL_DIR and link $FM_MACHINE_FM?"; then
    fm_skip "machine-wide fm declined — each account installs its own with: fm setup-onboard"
    return 0
  fi

  # uv runs as root here, so a uv anybody else can write is a way to be root.
  # That is not hypothetical on a box where the team shares a group: uv installs
  # itself into ~/.local/bin, and a home created under umask 002 leaves that
  # directory group-writable. The account this runs as already has sudo; every
  # other member of its group does not, and must not gain it here.
  refuse_writable_by_others "$uv" || return 0
  refuse_writable_by_others "$(dirname "$uv")" || return 0

  # A path anybody but root can replace is a path root must not install through.
  # /opt is root-owned, so this only fires when somebody has been at it by hand.
  if [ -L "$FM_CLI_TOOL_DIR" ]; then
    fm_warn "$FM_CLI_TOOL_DIR is a symlink to $(readlink -f "$FM_CLI_TOOL_DIR") — not installing through it"
    fm_info "inspect it, then remove it as root: rm -f $FM_CLI_TOOL_DIR"
    return 0
  fi

  # --python pins the venv to the system interpreter. Left to itself uv builds
  # against the interpreter it manages, which under sudo lands in /root at mode
  # 700 — and the shebang points straight at it, so the binary is unrunnable by
  # anyone but root however open its own mode is.
  if ! sudo env "UV_TOOL_DIR=$FM_CLI_TOOL_DIR" "UV_TOOL_BIN_DIR=$FM_CLI_BIN_DIR" \
       "$uv" tool install --force --python "$FM_CLI_PYTHON" "$(fm_tools_spec)"; then
    fm_warn "could not install the machine-wide CLI — only this account has fm on PATH"
    return 0
  fi

  # uv creates the tree under the invoking umask, which is root's. Read and
  # traverse for everyone is the whole point of installing it here, so it is set
  # rather than hoped for. Capital X adds execute to directories and to files
  # that already carry it, never to a data file.
  sudo chmod -R a+rX "$FM_CLI_TOOL_DIR"
  fm_ok "$FM_MACHINE_FM -> $(readlink -f "$FM_MACHINE_FM")"
}

do_uninstall() {
  local uv
  remove_machine_wide

  if ! uv="$(uv_bin)"; then
    fm_skip "uv not installed"
    return 0
  fi
  "$uv" tool uninstall fm-tools 2>/dev/null || fm_warn "fm-tools was not installed as a uv tool"
  # uv itself stays: other things on the machine may be using it, and this step
  # cannot know that it was the one that put it there.
  fm_info "uv left in place — remove it with: rm -rf ~/.local/bin/uv ~/.local/share/uv"
  fm_ok "fm CLI removed"
}

# Remove only the machine-wide install this step made. A command of the same
# name resolving anywhere else belongs to whoever put it there, and taking it
# away would leave everybody on the box without the CLI to undo a change they
# were never part of.
#
# The whole tool tree goes with the link. Leaving /opt/fm-tools behind would be
# a pinned CLI nothing points at, which the next install would silently reuse.
remove_machine_wide() {
  if [ ! -e "$FM_MACHINE_FM" ] && [ ! -d "$FM_CLI_TOOL_DIR" ]; then
    fm_skip "no machine-wide fm"
    return 0
  fi
  if [ -e "$FM_MACHINE_FM" ] && ! machine_fm_is_ours; then
    fm_skip "$FM_MACHINE_FM resolves outside $FM_CLI_TOOL_DIR"
    return 0
  fi
  # A tree with no command in front of it is not something this step can claim.
  # An install that died between writing the tree and writing the link leaves
  # exactly this, and so does a hand-made one — and the two are indistinguishable
  # from here. Named rather than deleted, because `sudo rm -rf` on a guess is the
  # one move an uninstall cannot take back.
  if [ ! -e "$FM_MACHINE_FM" ] && [ -d "$FM_CLI_TOOL_DIR" ]; then
    fm_warn "$FM_CLI_TOOL_DIR exists with no $FM_MACHINE_FM in front of it — leaving it"
    fm_info "remove it as root once you have looked: rm -rf $FM_CLI_TOOL_DIR"
    return 0
  fi
  if ! fm_has_cmd sudo; then
    fm_warn "no sudo here — $FM_MACHINE_FM left in place"
    fm_info "remove it as root: rm -rf $FM_MACHINE_FM $FM_CLI_TOOL_DIR"
    return 0
  fi
  if sudo rm -rf "$FM_MACHINE_FM" "$FM_CLI_TOOL_DIR"; then
    fm_ok "removed $FM_MACHINE_FM and $FM_CLI_TOOL_DIR"
  else
    fm_warn "could not remove $FM_MACHINE_FM — do it with: sudo rm -rf $FM_MACHINE_FM $FM_CLI_TOOL_DIR"
  fi
}

fm_dispatch "$@"
