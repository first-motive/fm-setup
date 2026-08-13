#!/usr/bin/env bash
#
# backup — copy the irreplaceable parts of /data to external storage, with a
# checksum manifest, and verify the copy before trusting it.
#
#   ./run.sh backup /mnt/ssd              copy + manifest + read-back verify
#   ./run.sh backup --verify /mnt/ssd     re-verify an existing backup
#   ./run.sh backup --restore /mnt/ssd    copy it back to /data, then verify
#
# What is backed up is what cannot be re-made: recordings, dataset releases, and
# run evidence. Model weights, caches, and container images are left out on
# purpose — they are downloads, and treating them as precious turns a 40-minute
# backup into an all-day one nobody runs.
#
# The manifest is plain `sha256sum -c` format, so it stays readable and
# verifiable with no tooling from this repo. A backup nobody verified is a
# rumour; the copy path verifies before it reports success.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$_here/../.." && pwd)"
# shellcheck source=../../lib.sh disable=SC1091
. "$FM_ROOT/lib.sh"
# shellcheck source=../manifest.sh disable=SC1091
. "$FM_ROOT/scripts/manifest.sh"

MANIFEST=MANIFEST.sha256
META=MANIFEST.meta

usage() {
  cat <<'EOF'
backup — copy /data's irreplaceables to external storage, with a verified manifest

Usage: ./run.sh backup [options] <destination>

  (no option)   copy, write a checksum manifest, then verify the copy
  --verify      verify an existing backup against its manifest, copy nothing
  --restore     copy the backup back to /data, then verify what landed
  --dry-run     show what would be copied, change nothing
  -h, --help    show this help

The destination is a mount point, e.g. /mnt/ssd. A subdirectory named after this
machine is created inside it, so one drive can hold more than one machine.
EOF
}

# Echo the backup root inside the destination: one directory per machine.
backup_root() { printf '%s/fm-backup-%s\n' "$1" "$(hostname -s)"; }

# Echo each source directory that exists, relative to FM_DATA_DIR.
present_sources() {
  local sub
  for sub in "${FM_BACKUP_SOURCES[@]}"; do
    [ -d "$FM_DATA_DIR/$sub" ] && printf '%s\n' "$sub"
  done
}

require_sources() {
  local count
  count="$(present_sources | grep -c . || true)"
  if [ "$count" -eq 0 ]; then
    fm_err "none of the backup sources exist under $FM_DATA_DIR"
    fm_info "expected: ${FM_BACKUP_SOURCES[*]}"
    return 1
  fi
}

do_copy() {
  local dest="$1" dry="$2" root sub
  root="$(backup_root "$dest")"
  require_sources

  fm_log "backing up $FM_DATA_DIR -> $root"
  while IFS= read -r sub; do
    fm_info "$sub  ($(du -sh "$FM_DATA_DIR/$sub" 2>/dev/null | cut -f1))"
  done < <(present_sources)

  if [ "$dry" = "1" ]; then
    fm_info "dry run — nothing copied"
    return 0
  fi

  mkdir -p "$root"
  while IFS= read -r sub; do
    # -aHAX --numeric-ids: keep permissions, hard links, ACLs, and xattrs, and
    # keep ids numeric so a restore onto a rebuilt machine does not remap
    # ownership to whoever happens to hold that name now.
    rsync -aHAX --numeric-ids --partial --info=progress2 \
      "$FM_DATA_DIR/$sub" "$root/"
  done < <(present_sources)

  write_manifest "$root"
  verify_manifest "$root"
}

write_manifest() {
  local root="$1"
  fm_log "writing $MANIFEST"
  # Relative paths, so the manifest verifies wherever the tree is mounted.
  # Built in a temp file and moved into place: writing it inside the tree being
  # hashed means the redirect creates the target before find walks past it.
  local tmp
  tmp="$(mktemp)"
  ( cd "$root" && find . -type f ! -name "$MANIFEST" ! -name "$META" -print0 \
      | sort -z | xargs -0 sha256sum ) > "$tmp"
  mv "$tmp" "$root/$MANIFEST"

  {
    printf 'machine:  %s\n' "$(hostname -f 2>/dev/null || hostname)"
    printf 'written:  %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'source:   %s\n' "$FM_DATA_DIR"
    printf 'contents: %s\n' "$(present_sources | tr '\n' ' ')"
    printf 'files:    %s\n' "$(wc -l < "$root/$MANIFEST" | tr -d ' ')"
    printf 'bytes:    %s\n' "$(du -sb "$root" 2>/dev/null | cut -f1)"
  } > "$root/$META"

  fm_ok "$(wc -l < "$root/$MANIFEST" | tr -d ' ') files recorded"
}

verify_manifest() {
  local root="$1"
  [ -f "$root/$MANIFEST" ] || { fm_err "no $MANIFEST at $root"; return 1; }

  fm_log "verifying every file against $MANIFEST"
  if ( cd "$root" && sha256sum --quiet -c "$MANIFEST" ); then
    fm_ok "every file matches its checksum"
  else
    fm_err "checksum mismatch — this backup cannot be trusted"
    return 1
  fi
}

do_restore() {
  local dest="$1" dry="$2" root sub
  root="$(backup_root "$dest")"
  [ -d "$root" ] || { fm_err "no backup at $root"; return 1; }

  # Verify before restoring, not after: copying a corrupt backup over /data
  # would destroy the only other copy.
  verify_manifest "$root"

  if [ "$dry" = "1" ]; then
    fm_info "dry run — would restore $root -> $FM_DATA_DIR"
    return 0
  fi

  fm_log "restoring $root -> $FM_DATA_DIR"
  for sub in "$root"/*/; do
    [ -d "$sub" ] || continue
    # No --delete: a restore adds what was saved and never removes what is
    # already there. Merging is recoverable; deleting is not.
    sudo rsync -aHAX --numeric-ids --partial --info=progress2 "$sub" "$FM_DATA_DIR/$(basename "$sub")/"
  done

  # The group is what makes /data shared; a restore that lands root-owned files
  # locks the team out of their own data.
  sudo chgrp -R "$FM_GROUP" "$FM_DATA_DIR"
  sudo chmod -R g+rwX "$FM_DATA_DIR"
  fm_ok "restored, group $FM_GROUP reapplied"
  fm_info "compare against the manifest with: ./run.sh backup --verify $dest"
}

main() {
  local mode="copy" dry=0 dest=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --verify)  mode="verify"; shift ;;
      --restore) mode="restore"; shift ;;
      --dry-run) dry=1; shift ;;
      -h|--help) usage; return 0 ;;
      -*) fm_err "unknown option: $1"; usage; return 1 ;;
      *) dest="$1"; shift ;;
    esac
  done

  if [ -z "$dest" ]; then
    fm_err "a destination is required"
    usage
    return 1
  fi

  fm_require_linux
  fm_require_cmd rsync
  fm_require_cmd sha256sum

  [ -d "$dest" ] || { fm_err "destination is not a directory: $dest"; return 1; }

  case "$mode" in
    copy)    do_copy "$dest" "$dry" ;;
    verify)  verify_manifest "$(backup_root "$dest")" ;;
    restore) do_restore "$dest" "$dry" ;;
  esac
}

main "$@"
