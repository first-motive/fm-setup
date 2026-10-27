from __future__ import annotations

import json
import os
from types import SimpleNamespace

import pytest

from fm_host_agent import diskscan

UID = os.getuid()


def allocated(path) -> int:
    return os.lstat(path).st_blocks * 512


def test_counts_allocated_blocks_once_per_hard_linked_file_and_follows_no_symlink(tmp_path):
    root = tmp_path / "data"
    (root / "a" / "b").mkdir(parents=True)
    big = root / "a" / "b" / "big"
    big.write_bytes(b"x" * 100_000)
    os.link(big, root / "a" / "again")
    outside = tmp_path / "outside"
    outside.write_bytes(b"y" * 200_000)
    (root / "link").symlink_to(outside)

    expected = sum(allocated(p) for p in (root, root / "a", root / "a" / "b", big, root / "link"))
    assert diskscan.scan([str(root)]) == {UID: expected}


def test_two_roots_sharing_a_hard_link_count_it_once(tmp_path):
    one, two = tmp_path / "one", tmp_path / "two"
    one.mkdir()
    two.mkdir()
    (one / "f").write_bytes(b"x" * 50_000)
    os.link(one / "f", two / "f")
    assert diskscan.scan([str(one), str(two)]) == {
        UID: allocated(one) + allocated(two) + allocated(one / "f")
    }


def test_a_missing_root_or_a_file_root_counts_nothing(tmp_path):
    (tmp_path / "file").write_bytes(b"x")
    assert diskscan.scan([str(tmp_path / "absent"), str(tmp_path / "file")]) == {}


def test_another_filesystem_below_a_root_is_not_walked(tmp_path, monkeypatch):
    root = tmp_path / "data"
    (root / "mnt").mkdir(parents=True)
    (root / "mnt" / "f").write_bytes(b"x" * 50_000)
    real_fstat, calls = os.fstat, []

    def root_on_its_own_device(fd):
        info = real_fstat(fd)
        calls.append(fd)
        if len(calls) > 1:
            return info
        # The root is the first descriptor stat'd; every entry below now sits on another device.
        return SimpleNamespace(
            st_mode=info.st_mode, st_uid=info.st_uid, st_blocks=info.st_blocks, st_nlink=1, st_dev=-1
        )

    monkeypatch.setattr(diskscan.os, "fstat", root_on_its_own_device)
    assert diskscan.scan([str(root)]) == {UID: allocated(root)}


def test_report_names_owners_largest_first_and_drops_empty_ones():
    body = diskscan.report({0: 10, 1: 30, 4_000_000: 20, 5: 0}, ["/data"], 7.0)
    assert body["scanned_at"] == 7.0 and body["roots"] == ["/data"]
    assert [row["bytes"] for row in body["users"]] == [30, 20, 10]
    assert body["users"][1]["user"] == "4000000"  # an owner with no account


def test_main_writes_a_readable_report_and_leaves_no_staging_file(tmp_path):
    root = tmp_path / "data"
    root.mkdir()
    out = tmp_path / "state" / "disk-users.json"
    out.parent.mkdir()
    assert diskscan.main(out, [str(root)]) == 0
    assert json.loads(out.read_text())["roots"] == [str(root)]
    assert oct(out.stat().st_mode & 0o777) == "0o644"
    assert os.listdir(out.parent) == ["disk-users.json"]


def test_a_failed_write_leaves_the_old_report_and_no_staging_file(tmp_path, monkeypatch):
    out = tmp_path / "disk-users.json"
    out.write_text("old")

    def no_rename(src, dst):
        raise OSError("disk full")

    monkeypatch.setattr(diskscan.os, "replace", no_rename)
    with pytest.raises(OSError):
        diskscan.write_atomically(out, {"users": []})
    assert out.read_text() == "old"
    assert os.listdir(tmp_path) == ["disk-users.json"]


@pytest.mark.skipif(os.geteuid() == 0, reason="root reads past the mode")
def test_an_unreadable_directory_is_skipped_and_the_rest_counted(tmp_path):
    root = tmp_path / "data"
    (root / "closed").mkdir(parents=True)
    (root / "open").mkdir()
    (root / "open" / "f").write_bytes(b"x" * 50_000)
    (root / "closed").chmod(0)
    try:
        expected = sum(allocated(p) for p in (root, root / "closed", root / "open", root / "open" / "f"))
        assert diskscan.scan([str(root)]) == {UID: expected}
    finally:
        (root / "closed").chmod(0o755)


def test_a_symlinked_root_is_not_followed(tmp_path):
    real = tmp_path / "real"
    real.mkdir()
    (real / "f").write_bytes(b"x" * 50_000)
    (tmp_path / "data").symlink_to(real)
    assert diskscan.scan([str(tmp_path / "data")]) == {}


def test_past_the_link_cap_a_file_is_counted_once_per_name(tmp_path):
    root = tmp_path / "data"
    root.mkdir()
    (root / "f").write_bytes(b"x" * 50_000)
    os.link(root / "f", root / "g")
    tally = diskscan.Tally(linked_max=0)
    diskscan.walk(str(root), tally)
    assert tally.bytes[UID] == allocated(root) + 2 * allocated(root / "f")


def test_a_root_that_cannot_be_listed_counts_itself_and_closes_its_descriptor(tmp_path, monkeypatch):
    root = tmp_path / "data"
    root.mkdir()
    (root / "f").write_bytes(b"x" * 50_000)
    closed = []
    real_close = os.close

    def no_listing(fd):
        raise OSError("EIO")

    def tracking_close(fd):
        closed.append(fd)
        real_close(fd)

    monkeypatch.setattr(diskscan.os, "scandir", no_listing)
    monkeypatch.setattr(diskscan.os, "close", tracking_close)
    assert diskscan.scan([str(root)]) == {UID: allocated(root)}
    assert len(closed) == 1
