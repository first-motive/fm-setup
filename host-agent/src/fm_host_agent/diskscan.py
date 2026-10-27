"""Who holds the space under /data and /home, by file owner.

Runs as root, once per request, from ``fm-host-disk-scan.service``: only root
can stat every account's files, and the agent that serves the answer never
holds that right. The agent starts the unit and reads the file this writes.

The walk counts what ``du`` would: allocated blocks, not apparent size, so a
sparse file counts what it occupies. It stays on each root's filesystem, so a
disk mounted below one is not charged to it, and counts a hard-linked file once
however many names it has.

It follows no symlink, including one swapped in mid-walk. The trees belong to
whoever can write under /home, so each directory is opened relative to its
parent's descriptor with ``O_NOFOLLOW`` and checked to be the directory that was
stat'd, rather than re-opened by a path someone else could change between the
two.
"""

from __future__ import annotations

import json
import os
import pwd
import stat
import sys
import tempfile
import time
from collections import defaultdict
from pathlib import Path

ROOTS = ("/data", "/home")
OUTPUT = Path("/var/lib/fm-host-agent/disk-users.json")
BLOCK_BYTES = 512  # st_blocks is in 512-byte units on Linux, whatever the filesystem's block size
DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
#: tradeoff: hard links are remembered to count each file once, and the set is
#: capped so a tree of millions of them cannot grow root's memory without end.
#: Past the cap a file with several names is counted once per name, an over-count.
LINKED_MAX = 500_000  # about 100 MB of tuples


def log(message: str) -> None:
    print(f"fm-host-disk-scan: {message}", file=sys.stderr, flush=True)


class Tally:
    """Bytes by owning uid, and the multiply-linked files already counted."""

    def __init__(self, linked_max: int = LINKED_MAX) -> None:
        self.bytes: dict[int, int] = defaultdict(int)
        self.linked: set[tuple[int, int]] = set()
        self.linked_max = linked_max
        self.capped = False

    def add(self, info: os.stat_result) -> None:
        if not stat.S_ISDIR(info.st_mode) and info.st_nlink > 1:
            key = (info.st_dev, info.st_ino)
            if key in self.linked:
                return
            if len(self.linked) < self.linked_max:
                self.linked.add(key)
            elif not self.capped:
                log(f"over {self.linked_max} hard-linked files; the rest may be counted once per name")
                self.capped = True
        self.bytes[info.st_uid] += info.st_blocks * BLOCK_BYTES


def walk(root: str, tally: Tally) -> None:
    """Add everything under ``root`` on its own filesystem to ``tally``. A missing root adds nothing."""
    try:
        top_fd = os.open(root, DIR_FLAGS)
    except OSError:
        return  # absent, or a symlink or file where a directory was expected
    top = os.fstat(top_fd)
    tally.add(top)
    try:
        top_entries = os.scandir(top_fd)
    except OSError:
        os.close(top_fd)
        log(f"cannot list {root}; counted its own size only")
        return
    # Descriptors are held only along the current path, so the walk's open
    # files are bounded by the tree's depth, not its width.
    stack = [(top_fd, top_entries)]
    while stack:
        fd, entries = stack[-1]
        try:
            entry = next(entries, None)
        except OSError:
            entry = None  # an I/O error mid-listing ends this directory, not the scan
        if entry is None:
            entries.close()
            os.close(fd)
            stack.pop()
            continue
        try:
            info = entry.stat(follow_symlinks=False)
        except OSError:
            continue  # removed since it was listed
        if info.st_dev != top.st_dev:
            continue  # a mount point: another filesystem, reported as its own mount
        tally.add(info)
        if not stat.S_ISDIR(info.st_mode):
            continue
        try:
            child = os.open(entry.name, DIR_FLAGS, dir_fd=fd)
        except OSError:
            continue  # replaced by a symlink or removed since it was stat'd
        opened = os.fstat(child)
        if (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino):
            os.close(child)  # replaced by another directory since it was stat'd
            continue
        try:
            stack.append((child, os.scandir(child)))
        except OSError:
            os.close(child)


def scan(roots) -> dict[int, int]:
    """Bytes allocated under ``roots``, by owning uid."""
    tally = Tally()
    for root in roots:
        walk(root, tally)
    return dict(tally.bytes)


def user_name(uid: int) -> str:
    """The account's name, or the bare uid for a file whose owner was deleted."""
    try:
        return pwd.getpwuid(uid).pw_name
    except KeyError:
        return str(uid)


def report(totals: dict[int, int], roots, scanned_at: float) -> dict:
    users = [{"user": user_name(uid), "bytes": size} for uid, size in totals.items() if size > 0]
    users.sort(key=lambda row: (-row["bytes"], row["user"]))
    return {"scanned_at": scanned_at, "roots": list(roots), "users": users}


def write_atomically(path: Path, body: dict) -> None:
    """Replace ``path`` in one rename, so the agent never reads half a report."""
    fd, staged = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as out:
            json.dump(body, out, sort_keys=True)
            out.flush()
            os.fsync(out.fileno())
        os.chmod(staged, 0o644)  # mkstemp makes it 0600; the agent's account reads it
        os.replace(staged, path)
    except BaseException:
        os.unlink(staged)
        raise


def main(out: Path = OUTPUT, roots=ROOTS) -> int:
    started = time.monotonic()
    body = report(scan(roots), roots, time.time())
    write_atomically(out, body)
    log(f"{len(body['users'])} owners under {', '.join(roots)} in {time.monotonic() - started:.0f} s")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
