#!/usr/bin/env bash
#
# service-lib.sh — what every First Motive service step does the same way: its
# test hooks, its account, the root-owned tree it builds its service in, the
# pinned uv and root-built venv, the files it installs, and the trees it
# removes. Sourced by 91-sim.sh (through sim-lib.sh), 93-host-agent.sh and
# 94-twin.sh; each step's own test suite exercises it through that step.
#
# Each of those steps keeps its service under one root-owned tree, laid out the
# same way, and these functions take that tree as ROOT:
#
#   ROOT/project         the service's source, copied in by the step
#   ROOT/venv            built from it here, as root, non-editable
#   ROOT/bin/uv          Astral's release at FM_UV_VERSION, checked against
#                        FM_UV_SHA256_MAP before it is unpacked
#   ROOT/bin/.uv-sha256  the checksum the installed uv was checked against
#
# R is the caller's test root: empty on a real host, a temp directory under a
# step's test hooks. Every path a message names is the installed one, without it.
#
# Requires lib.sh (fm_err, fm_log, fm_ok) and scripts/manifest.sh to be sourced
# first.

# svc_must WHAT CMD… — run CMD; on failure say WHAT failed and return 1. Every
# privileged command goes through this or an explicit `|| {…}`, because errexit
# does not hold inside a function its caller tests with `||`.
svc_must() {
  local what="$1"; shift
  "$@" && return 0
  fm_err "$what failed"
  return 1
}

# svc_test_knob SWITCH NAME — echo the test hook NAME's value, or refuse it
# unless the step's test switch SWITCH is 1.
svc_test_knob() {
  local switch="$1" value="${!2:-}"
  [ -n "$value" ] || return 0
  [ "${!switch:-0}" = 1 ] || { fm_err "$2 is a test hook and needs $switch=1 — refusing"; return 1; }
  printf '%s\n' "$value"
}

# svc_safe_word WORD — 0 when WORD is safe in a unit's command line or paths.
#
# A space splits an argument, `%` and `$` are expanded by systemd itself, and
# quotes and backslashes change how systemd splits the line, so a value
# carrying one would start the service with words nobody wrote.
svc_safe_word() {
  case "$1" in
    "" | *[[:space:]]* | *%* | *\$* | *\"* | *\'* | *\\* | *\;*)
      fm_err "refusing '$1' in the service's unit — no spaces, quotes, %, \$, \\ or ;"
      return 1 ;;
  esac
}

# svc_tree_ok — read `git ls-tree -r` output on stdin; 0 when it lists at least
# one entry and every entry is a plain file (mode 100644 or 100755).
#
# Checked before anything is extracted: a symlink in the tree would let the
# copy point the service at a path outside it, and a submodule is code the pin
# does not cover.
svc_tree_ok() {
  local mode rest count=0
  while read -r mode rest; do
    [ -n "$mode" ] || continue
    case "$mode" in
      100644 | 100755) count=$((count + 1)) ;;
      *) fm_err "refusing a tree entry of mode $mode: ${rest#*$'\t'}"; return 1 ;;
    esac
  done
  [ "$count" -gt 0 ] || { fm_err "the tree is empty"; return 1; }
}

# svc_tar_ok — read `tar -tv` output on stdin; 0 when it lists at least one
# entry and every entry is a plain file or a directory.
#
# Checked before root extracts anything: a symlink entry followed by a path
# through it writes wherever the link points, and a hard link or device is
# nothing a service tree holds.
svc_tar_ok() {
  local line count=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      -* | d*) count=$((count + 1)) ;;
      *) fm_err "refusing an archive entry that is not a plain file or directory: $line"; return 1 ;;
    esac
  done
  [ "$count" -gt 0 ] || { fm_err "the archive is empty"; return 1; }
}

# svc_test_root_ok VAR PREFIX — 0 when PREFIX, the value of the test hook named
# VAR, may stand in for / in a test run: under the temp directory, and holding
# no '..', so the hook cannot point a real install anywhere that matters.
svc_test_root_ok() {
  local var="$1" prefix="$2" tmp="${TMPDIR:-/tmp}"
  tmp="${tmp%/}"
  # A temp dir of / would make every path "under" it.
  [ -n "$tmp" ] || { fm_err "no temp directory to hold $var — refusing"; return 1; }
  case "$prefix" in *..*) fm_err "$var must not hold '..': $prefix"; return 1 ;; esac
  [ "${prefix#"$tmp"/}" != "$prefix" ] && [ -n "${prefix#"$tmp"/}" ] && return 0
  fm_err "$var must sit under $tmp/: $prefix"
  return 1
}

# svc_uv_sha [OVERRIDE] — the uv tarball's pinned sha256 for this machine's
# architecture, or OVERRIDE when a test hook names one.
svc_uv_sha() {
  local arch entry
  if [ -n "${1:-}" ]; then printf '%s\n' "$1"; return 0; fi
  arch="$(uname -m)"
  for entry in "${FM_UV_SHA256_MAP[@]}"; do
    [ "${entry%%|*}" = "$arch" ] && { printf '%s\n' "${entry#*|}"; return 0; }
  done
  fm_err "no uv checksum pinned for $arch — add it to FM_UV_SHA256_MAP"
  return 1
}

# svc_uv_current R ROOT SHA — 0 when ROOT/bin/uv is the uv checked against SHA.
# Never for an empty SHA: no pin is not a match.
svc_uv_current() {
  [ -n "$3" ] && [ -x "$1$2/bin/uv" ] && [ "$(cat "$1$2/bin/.uv-sha256" 2>/dev/null)" = "$3" ]
}

# svc_install_uv R ROOT SHA — Astral's release tarball at FM_UV_VERSION into
# ROOT/bin/uv, checked against SHA before it is unpacked. ROOT must exist.
svc_install_uv() {
  local r="$1" root="$2" sha="$3" uv="$2/bin/uv" arch stage actual
  [ -n "$sha" ] || { fm_err "no uv checksum to check $uv against — refusing to install it"; return 1; }
  if svc_uv_current "$r" "$root" "$sha"; then
    fm_ok "$uv is the pinned uv $FM_UV_VERSION"
    return 0
  fi
  arch="$(uname -m)"
  svc_must "creating $root/bin" sudo install -d -o root -g root -m 0755 "$r$root/bin" || return 1
  stage="$(sudo mktemp -d "$r$root/.uv.XXXXXX")" || { fm_err "creating a staging directory failed"; return 1; }
  fm_log "fetching uv $FM_UV_VERSION ($arch)"
  if ! svc_must "downloading uv $FM_UV_VERSION" sudo curl -fsSL --proto '=https' --proto-redir '=https' -o "$stage/uv.tar.gz" \
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
  if ! { svc_must "unpacking uv" sudo tar -xzf "$stage/uv.tar.gz" --no-same-owner -C "$stage" \
      && svc_must "installing $uv" sudo install -o root -g root -m 0755 \
           "$stage/uv-$arch-unknown-linux-gnu/uv" "$r$uv"; }; then
    sudo rm -rf "$stage"
    return 1
  fi
  sudo rm -rf "$stage"
  printf '%s\n' "$sha" | sudo tee "$r$root/bin/.uv-sha256" >/dev/null \
    || { fm_err "recording the uv checksum failed"; return 1; }
  fm_ok "$uv is uv $FM_UV_VERSION (sha256 verified)"
}

# svc_build_venv R ROOT CACHE — build ROOT/venv as root from ROOT/project with
# ROOT/bin/uv, and nothing inherited: no uv config file, no index override, no
# PATH beyond the system's, no downloaded Python. Frozen to the project's
# uv.lock and non-editable, so the venv holds the service and its unit starts
# the venv's entrypoint and runs no uv. The caller checks the entrypoints.
svc_build_venv() {
  local r="$1" root="$2" cache="$3"
  svc_must "creating $cache" sudo install -d -o root -g root -m 0700 "$r$cache" || return 1
  fm_log "building $root/venv (as root, from $root/project)"
  svc_must "building $root/venv" sudo env -i PATH=/usr/bin:/bin HOME=/nonexistent UV_NO_CONFIG=1 \
    "UV_PROJECT_ENVIRONMENT=$r$root/venv" "UV_CACHE_DIR=$r$cache" \
    "UV_PYTHON=$FM_CLI_PYTHON" UV_PYTHON_DOWNLOADS=never \
    "$r$root/bin/uv" sync --quiet --frozen --no-dev --no-editable --directory "$r$root/project" || return 1
  svc_must "setting venv modes" sudo chmod -R u+rwX,go+rX,go-w "$r$root/venv"
}

# svc_ensure_account USER [HOME] — a system account with no login: with HOME,
# that home made; without, none.
svc_ensure_account() {
  local user="$1" home="${2:-}"
  if getent passwd "$user" >/dev/null 2>&1; then
    fm_ok "account $user present"
    return 0
  fi
  fm_log "creating system account $user"
  if [ -n "$home" ]; then
    svc_must "creating account $user" sudo useradd --system --user-group --create-home \
      --home-dir "$home" --shell /usr/sbin/nologin "$user" || return 1
  else
    svc_must "creating account $user" sudo useradd --system --user-group --no-create-home \
      --home-dir /nonexistent --shell /usr/sbin/nologin "$user" || return 1
  fi
  fm_ok "account $user created"
}

# svc_seal_tree R SRC DEST — hand the staged tree SRC to root, directories 755
# and files 644, and move it into place at DEST, replacing what was there. The
# caller removes its staging directory on a failure.
svc_seal_tree() {
  local r="$1" src="$2" dest="$3"
  svc_must "handing $dest to root" sudo chown -R root:root "$src" \
    && svc_must "setting directory modes" sudo find "$src" -type d -exec chmod 0755 {} + \
    && svc_must "setting file modes" sudo find "$src" -type f -exec chmod 0644 {} + \
    && svc_must "creating $(dirname "$dest")" sudo install -d -o root -g root -m 0755 "$(dirname "$r$dest")" \
    && svc_must "removing the old $dest" sudo rm -rf "$r$dest" \
    && svc_must "moving the new $dest into place" sudo mv "$src" "$r$dest"
}

# svc_install_file R STAGE_IN DEST TEXT — write TEXT to DEST, root:root 0644,
# staged in a root-owned directory under STAGE_IN (never a file the invoking
# account owns). 0 when written, 3 when DEST already held TEXT, 1 on a failure.
# The caller reloads systemd.
svc_install_file() {
  local r="$1" stage_in="$2" dest="$3" text="$4" stage rc=0
  if [ -f "$r$dest" ] && [ "$(cat "$r$dest")" = "$text" ]; then
    fm_ok "$dest current"
    return 3
  fi
  stage="$(sudo mktemp -d "$r$stage_in/.unit.XXXXXX")" || { fm_err "creating a staging directory failed"; return 1; }
  if ! printf '%s\n' "$text" | sudo tee "$stage/unit" >/dev/null; then
    fm_err "staging $dest failed"
    rc=1
  elif ! { svc_must "creating $(dirname "$dest")" sudo install -d -m 0755 "$(dirname "$r$dest")" \
      && svc_must "writing $dest" sudo install -o root -g root -m 0644 "$stage/unit" "$r$dest"; }; then
    rc=1
  fi
  sudo rm -rf "$stage"
  [ "$rc" = 0 ] || return 1
  fm_ok "wrote $dest"
}

# svc_remove_tree R STEP PATH ALLOWED… — rm -rf PATH, one of the step's own
# trees, only when it is one of ALLOWED. The caller names ALLOWED literally
# rather than through the manifest's variables, so an edit there cannot widen a
# root rm.
svc_remove_tree() {
  local r="$1" step="$2" path="$3" allowed
  shift 3
  for allowed in "$@"; do
    [ "$path" = "$allowed" ] || continue
    if [ -d "$r$path" ]; then
      svc_must "removing $path" sudo rm -rf "$r$path" || return 1
      fm_ok "$path removed"
    fi
    return 0
  done
  fm_warn "not removing $path — not one of the $step step's trees; remove it by hand"
}
