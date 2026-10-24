#!/usr/bin/env bash
#
# ghcr-lib.sh — the sim-cloud role's one-pull GHCR login, sourced by
# scripts/steps/91-sim.sh and tested directly by scripts/dev/test-sim-cloud.sh.
#
# A cloud host has nobody to run docker login, so the stack names a GHCR token
# in SSM (FM_GHCR_TOKEN_SSM_PARAMETER, read through the instance role) and the
# login it belongs to (FM_GHCR_USERNAME). The token is a credential and
# cloud-init copies this run's output to the console log, so it is handled as
# 61-tailscale-authkey handles its key:
#
#   - aws writes it straight into a 0600 file in a 0700 directory under /run,
#     a tmpfs, and docker login reads it on stdin, so argv never holds it;
#   - the login lands in a DOCKER_CONFIG inside that directory, used for the
#     one pull, so no docker config outlives it: the login sits on tmpfs until
#     destroy_ghcr removes the directory;
#   - the directory is shredded whether the pull worked or not, and on a
#     signal too; its shape is checked without printing it.
#
# The image stays in the local store, so runs start from it with no login.
#
# Requires lib.sh (fm_err, fm_log, fm_ok, fm_has_cmd) sourced first, and R, the
# test root prefix (empty on a real host).

GHCR_DIR=""

# ghcr_pull_needed — 0 when this host pulls with the stack's token: the
# sim-cloud role running the controllers image. A workstation's controllers
# pull uses the operator's own docker login, through pull_image.
ghcr_pull_needed() {
  [ "${FM_ROLE:-}" = sim-cloud ] && [ "${FM_SIM_CONTROLLERS:-0}" = 1 ]
}

destroy_ghcr() {
  [ -n "$GHCR_DIR" ] || return 0
  # The token, and the login docker wrote from it (base64 of user:token).
  local f
  for f in "$GHCR_DIR/token" "$GHCR_DIR/docker/config.json"; do
    [ -f "$f" ] || continue
    if fm_has_cmd shred; then shred -u "$f" 2>/dev/null || rm -f "$f"; else rm -f "$f"; fi
  done
  rm -rf "$GHCR_DIR"
  GHCR_DIR=""
}

# Read the token into FILE. Nothing the token passes through is printed.
read_ghcr_token() {
  local file="$1" err="$2"
  if ! aws ssm get-parameter --region "$FM_SIM_CLOUD_REGION" --name "$FM_GHCR_TOKEN_SSM_PARAMETER" \
       --with-decryption --query Parameter.Value --output text >"$file" 2>"$err"; then
    # aws reports why it could not read the parameter, never its value.
    fm_err "could not read $FM_GHCR_TOKEN_SSM_PARAMETER in $FM_SIM_CLOUD_REGION:"
    sed 's/^/        /' "$err" >&2
    return 1
  fi
  # A classic or fine-grained GitHub token. Checked in place: grep -q prints nothing.
  if [ "$(wc -l <"$file")" -gt 1 ] || ! grep -Eqx '(ghp_|github_pat_)[A-Za-z0-9_]+' "$file"; then
    fm_err "$FM_GHCR_TOKEN_SSM_PARAMETER does not hold a GitHub token (want ghp_… or github_pat_…; the value is not shown)"
    return 1
  fi
}

# Log in, pull REF, and forget the login. A failure is an error here, not a
# warning: a cloud host that cannot pull its image cannot serve a run.
ghcr_pull() {
  local ref="$1" rc=0 mask prev
  # The caller's traps come back afterwards; ours only cover the token's life.
  prev="$(trap -p INT TERM HUP EXIT)"
  trap 'destroy_ghcr; exit 1' INT TERM HUP
  trap destroy_ghcr EXIT
  # 077 for everything made here: the token file is written by redirection.
  mask="$(umask)"
  umask 077
  GHCR_DIR="$(mktemp -d "$R/run/fm-ghcr.XXXXXX")" || { umask "$mask"; fm_err "creating a token directory under /run failed"; return 1; }
  if read_ghcr_token "$GHCR_DIR/token" "$GHCR_DIR/aws.err"; then
    fm_log "logging in to ghcr.io as $FM_GHCR_USERNAME for one pull"
    if DOCKER_CONFIG="$GHCR_DIR/docker" docker login ghcr.io -u "$FM_GHCR_USERNAME" --password-stdin \
         <"$GHCR_DIR/token" >/dev/null 2>"$GHCR_DIR/login.err"; then
      fm_log "pulling $ref"
      DOCKER_CONFIG="$GHCR_DIR/docker" docker pull "$ref" || { fm_err "could not pull $ref"; rc=1; }
    else
      fm_err "docker login ghcr.io as $FM_GHCR_USERNAME failed:"
      sed 's/^/        /' "$GHCR_DIR/login.err" >&2
      rc=1
    fi
  else
    rc=1
  fi
  destroy_ghcr
  umask "$mask"
  trap - INT TERM HUP EXIT
  eval "$prev"
  [ "$rc" = 0 ] && fm_ok "$ref pulled; the login is gone"
  return "$rc"
}

