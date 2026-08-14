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
# Per-user, not system-wide: uv puts tools under the invoking user's home. A
# second person on the box runs this step (or fm-tools' install.sh) for
# themselves. Nothing here uses sudo.

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

do_check() {
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
}

do_uninstall() {
  local uv
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

fm_dispatch "$@"
