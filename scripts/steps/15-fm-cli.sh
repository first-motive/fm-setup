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
# uv puts tools under the invoking user's home, so the install itself is
# per-user. On top of that this step links /usr/local/bin/fm at the binary uv
# wrote, because a newcomer with an empty home has no ~/.local/bin on PATH and
# nothing to run: the CLI is how they onboard, so it cannot be the thing that
# waits until they have onboarded. One link means one pinned version for the
# whole box and upgrades that only the administrator can make.

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

# Where a system-wide `fm` lives.
FM_SHIM=/usr/local/bin/fm

# This account's uv tool binary — the thing the shim points at. uv writes tool
# entry points here whether or not the directory is on PATH, which is the same
# reason uv_bin looks there directly.
uv_tool_fm() { printf '%s\n' "$HOME/.local/bin/fm"; }

# Return success when the shim is the one this account installed. Both sides are
# resolved before they are compared, because a shim installed from another
# account is that person's pin and this step may neither move nor remove it.
shim_is_ours() {
  [ -L "$FM_SHIM" ] && [ "$(readlink -f "$FM_SHIM")" = "$(readlink -f "$(uv_tool_fm)")" ]
}

# The shim resolves into this account's home, and Ubuntu creates a home at mode
# 750: every other account then gets "Permission denied" from a link that looks
# perfectly healthy to the person who made it. Said out loud, never fixed here —
# a home directory belongs to the person living in it, not to this step.
#
# Both directories the link resolves through, because either one closed to
# others stops the same command in the same way.
warn_unless_traversable() {
  local dir mode
  for dir in "$HOME" "$(dirname "$(uv_tool_fm)")"; do
    mode="$(stat -c '%a' "$dir" 2>/dev/null)" || continue
    # 0001 is the other-execute bit, which on a directory is the right to enter it.
    if [ $(( 8#$mode & 0001 )) -eq 0 ]; then
      fm_warn "$dir is mode $mode — every other account gets 'Permission denied' from $FM_SHIM"
      fm_info "its owner makes the shim usable for the team with: chmod o+x $dir"
    fi
  done
}

# Fail when anyone but the owner can write a directory the shim resolves
# through.
#
# The shim makes one account's binary the `fm` every other account runs. If a
# second person can write $HOME or ~/.local/bin — a home left group-writable on
# a machine where the whole team is in one group — they can replace that binary,
# and it then runs as whoever typed `fm`. The link would hand a shared group a
# way to execute code as each other, which is precisely the boundary the fm
# group exists to keep.
#
# Checked rather than fixed, and checked immediately before the link is made:
# these are somebody's own directories, and a step that silently tightened them
# would be changing a home it does not own.
shim_target_is_private() {
  local dir mode
  for dir in "$HOME" "$(dirname "$(uv_tool_fm)")"; do
    mode="$(stat -c '%a' "$dir" 2>/dev/null)" || continue
    # 0022 is the group-write and other-write bits, and nothing else.
    if [ $(( 8#$mode & 0022 )) -ne 0 ]; then
      fm_warn "$dir is mode $mode — anyone who can write it decides what every account's fm runs"
      fm_info "not linking $FM_SHIM; make it private first: chmod go-w $dir"
      return 1
    fi
  done
}

do_check() {
  check_user_install
  check_shim
  return 0
}

check_shim() {
  if shim_is_ours; then
    fm_ok "$FM_SHIM -> $(uv_tool_fm)"
    warn_unless_traversable
  elif [ -e "$FM_SHIM" ]; then
    fm_warn "$FM_SHIM points at another install ($(readlink -f "$FM_SHIM")), not this account's"
  else
    fm_warn "no $FM_SHIM — an account that has installed nothing has no fm on PATH"
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

  install_shim
}

# Link /usr/local/bin at this account's uv tool binary, so every account on the
# box has fm on PATH.
#
# Every obstacle here is a skip rather than a failure: the per-user install above
# has already succeeded by the time this runs, and an administrator who cannot
# write /usr/local/bin still has a working CLI. A step that went red at this
# point would report a machine as unprovisioned over a convenience.
install_shim() {
  if shim_is_ours; then
    fm_ok "$FM_SHIM -> $(uv_tool_fm)"
    warn_unless_traversable
    return 0
  fi

  if [ -e "$FM_SHIM" ]; then
    # Somebody else installed this one, and their pin is the one the box is
    # running. Overwriting it would move every other account onto this account's
    # CLI without anyone asking for that.
    fm_warn "$FM_SHIM already points at another install ($(readlink -f "$FM_SHIM")) — leaving it"
    fm_info "whoever owns that link removes it; this account can then take the pin"
    return 0
  fi

  if ! fm_has_cmd sudo; then
    fm_skip "no sudo here — $FM_SHIM not linked, so only this account has fm on PATH"
    return 0
  fi

  # Writing into /usr/local/bin decides which CLI the whole machine runs, so it
  # is asked for rather than assumed, and an unattended run declines and says so.
  fm_warn "$FM_SHIM makes this account's pinned CLI the one every account on the box runs"
  if ! fm_confirm "Link $FM_SHIM to $(uv_tool_fm)?"; then
    fm_skip "system-wide fm declined — each account installs its own with: fm setup-onboard"
    return 0
  fi

  # After the prompt rather than before it, so the gap between deciding the
  # target is private and linking to it is not however long somebody took to
  # answer a question.
  shim_target_is_private || return 0

  # A symlink rather than a wrapper script: a uv tool binary is a self-contained
  # entry point naming its own venv interpreter, so it resolves to the right
  # Python from wherever it is reached and needs nothing set in the environment.
  if sudo ln -s "$(uv_tool_fm)" "$FM_SHIM"; then
    fm_ok "linked $FM_SHIM -> $(uv_tool_fm)"
    warn_unless_traversable
  else
    fm_warn "could not write $FM_SHIM — only this account has fm on PATH"
  fi
}

do_uninstall() {
  local uv
  # Before the binary it points at goes, so the machine is never left with a
  # shim resolving to nothing.
  remove_shim

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

# Remove only the shim this step made. One pointing anywhere else is another
# account's, and taking it away would leave everybody on the machine without the
# CLI to undo a change they were never part of.
remove_shim() {
  if shim_is_ours; then
    if ! fm_has_cmd sudo; then
      # Said rather than swallowed: the binary underneath is about to go, and a
      # shim left pointing at nothing is `fm: No such file or directory` for
      # every account on the machine.
      fm_warn "no sudo here — $FM_SHIM will point at nothing once the CLI is gone"
      fm_info "remove it as root: rm -f $FM_SHIM"
      return 0
    fi
    if sudo rm -f "$FM_SHIM"; then
      fm_ok "removed $FM_SHIM"
    else
      fm_warn "could not remove $FM_SHIM — do it with: sudo rm -f $FM_SHIM"
    fi
  elif [ -e "$FM_SHIM" ]; then
    fm_skip "$FM_SHIM points at another account's install"
  fi
}

fm_dispatch "$@"
