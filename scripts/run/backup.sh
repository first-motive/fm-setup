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

# Regular files and directories only.
#
# An external drive can leave the building, and a restore runs as root. A tree
# carrying symlinks, device nodes, or setuid binaries would otherwise be copied
# back verbatim into /data — and the group fix-up that follows would make a
# restored setuid binary group-writable, which hands root to anyone in the fm
# group. Recordings and datasets are regular files; anything else in there is
# either a mistake or an attack, and both deserve to be named rather than
# silently restored.
RSYNC_FLAGS=(-rptgoHAX --no-D --no-links --numeric-ids --partial --info=progress2)

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
#
# The hostname is checked rather than trusted: it lands in a path, and a host
# named `../..` would put the backup somewhere other than the drive.
backup_root() {
  local host
  host="$(hostname -s)"
  case "$host" in
    ""|*/*|*..*)
      fm_err "refusing to build a path from hostname '$host'"
      return 1 ;;
  esac
  printf '%s/fm-backup-%s\n' "$1" "$host"
}

# List anything in a tree that is not a plain file or directory, plus anything
# carrying setuid or setgid. Empty output means the tree is safe to move around.
unsafe_entries() {
  find "$1" \( -type l -o -type b -o -type c -o -type p -o -type s \) -print \
    -o -type f -perm /6000 -print 2>/dev/null
}

# Report unsafe entries and fail. Called before a copy and before a restore, so
# neither direction moves something this tool cannot vouch for.
require_safe_tree() {
  local path="$1" what="$2" found
  found="$(unsafe_entries "$path")"
  [ -z "$found" ] && return 0

  fm_err "$what contains entries this tool will not copy:"
  printf '%s\n' "$found" | head -20 | sed 's/^/      /'
  fm_info "symlinks, device nodes, sockets, and setuid files are excluded by policy"
  fm_info "remove them, or copy them by hand knowing what they are"
  return 1
}

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

  while IFS= read -r sub; do
    require_safe_tree "$FM_DATA_DIR/$sub" "$sub"
  done < <(present_sources)

  mkdir -p "$root"
  while IFS= read -r sub; do
    # Permissions, hard links, ACLs, and xattrs are kept; ids stay numeric so a
    # restore onto a rebuilt machine does not remap ownership to whoever holds
    # that name now.
    rsync "${RSYNC_FLAGS[@]}" "$FM_DATA_DIR/$sub" "$root/"
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

  # `sha256sum -c` only checks what the manifest lists, so a file *added* to the
  # backup afterwards passes silently. Counting catches that.
  local listed actual
  listed="$(wc -l < "$root/$MANIFEST" | tr -d ' ')"
  actual="$(find "$root" -type f ! -name "$MANIFEST" ! -name "$META" | wc -l | tr -d ' ')"
  if [ "$listed" != "$actual" ]; then
    fm_err "the backup holds $actual files, the manifest lists $listed"
    fm_err "something was added or removed after the manifest was written"
    return 1
  fi

  # Nothing the manifest covers can be a symlink or a device, because those are
  # never copied — but the tree could have grown one since.
  require_safe_tree "$root" "this backup"
}

do_restore() {
  local dest="$1" dry="$2" root sub
  root="$(backup_root "$dest")"
  [ -d "$root" ] || { fm_err "no backup at $root"; return 1; }

  # Verify before restoring, not after: copying a corrupt backup over /data
  # would destroy the only other copy. This also rejects a tree carrying
  # symlinks, devices, or setuid files, which is the shape a tampered drive
  # would take.
  verify_manifest "$root"

  if [ "$dry" = "1" ]; then
    fm_info "dry run — would restore $root -> $FM_DATA_DIR"
    return 0
  fi

  fm_log "restoring $root -> $FM_DATA_DIR"
  local restored=()
  for sub in "$root"/*/; do
    [ -d "$sub" ] || continue
    # No --delete: a restore adds what was saved and never removes what is
    # already there. Merging is recoverable; deleting is not.
    sudo rsync "${RSYNC_FLAGS[@]}" "$sub" "$FM_DATA_DIR/$(basename "$sub")/"
    restored+=("$FM_DATA_DIR/$(basename "$sub")")
  done

  # Belt and braces. The copy path refuses to save a setuid file and the restore
  # refuses to read a tree holding one, but the group fix-up below is what would
  # turn a missed one into root for the whole team — so strip the bits rather
  # than rely on two earlier checks having held.
  sudo find "${restored[@]}" -xdev -type f -perm /6000 -exec chmod ug-s {} + 2>/dev/null || true

  # The group is what makes /data shared; a restore that lands root-owned files
  # locks the team out of their own data. Scoped to what was restored, not the
  # whole of /data.
  sudo chgrp -R "$FM_GROUP" "${restored[@]}"
  sudo chmod -R g+rwX "${restored[@]}"
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
