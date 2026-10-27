from __future__ import annotations

import json

import pytest

from fm_host_agent.diskusers import RESCAN_S, STALE_S, DiskUsers, parse_request
from tests.fakes import Systemd

REPORT = {"scanned_at": 1000.0, "roots": ["/data", "/home"], "users": [{"user": "ana", "bytes": 5}]}


@pytest.fixture
def clock():
    return {"t": 1000.0}


@pytest.fixture
def systemd():
    return Systemd()


@pytest.fixture
def report(tmp_path):
    return tmp_path / "disk-users.json"


@pytest.fixture
def disk(report, systemd, clock):
    # One clock stands in for both: the tests move them together.
    return DiskUsers(
        report, start=systemd.start, running=systemd.running, now=lambda: clock["t"], clock=lambda: clock["t"]
    )


def ask(disk, **request) -> dict:
    return disk.answer(json.dumps(request).encode() if request else None)


def test_no_report_starts_a_scan_and_says_so(disk, systemd):
    body = ask(disk)
    assert body == {
        "ok": True,
        "state": "scanning",
        "scanned_at": None,
        "roots": ["/data", "/home"],
        "users": [],
    }
    assert systemd.starts == 1


def test_a_fresh_report_is_served_without_a_scan(disk, systemd, report, clock):
    report.write_text(json.dumps(REPORT))
    clock["t"] = 1000.0 + STALE_S
    assert ask(disk)["state"] == "idle"
    assert ask(disk)["users"] == REPORT["users"]
    assert systemd.starts == 0


def test_a_stale_report_is_served_while_a_new_scan_runs(disk, systemd, report, clock):
    report.write_text(json.dumps(REPORT))
    clock["t"] = 1001.0 + STALE_S
    body = ask(disk)
    assert (body["state"], body["scanned_at"]) == ("scanning", 1000.0)
    assert ask(disk)["state"] == "scanning"
    assert systemd.starts == 1


def test_refresh_inside_the_spacing_is_refused_and_after_it_starts_a_scan(disk, systemd, clock):
    ask(disk)
    systemd.active = False
    disk.finished()
    clock["t"] += RESCAN_S - 1
    body = ask(disk, refresh=True)
    assert body["ok"] is False and body["error"]["code"] == "too_soon"
    clock["t"] += 1
    assert ask(disk, refresh=True)["state"] == "scanning"
    assert systemd.starts == 2


def test_the_running_state_is_read_from_the_watch_not_from_systemd_per_query(disk, systemd):
    ask(disk)
    systemd.active = False
    assert ask(disk)["state"] == "scanning"  # until finished() has seen it end
    disk.finished()
    assert ask(disk)["state"] == "idle"


def test_refresh_while_scanning_is_not_refused(disk, systemd):
    ask(disk)
    assert ask(disk, refresh=True)["state"] == "scanning"
    assert systemd.starts == 1


def test_a_failed_scan_is_not_restarted_by_every_viewer(disk, systemd, clock, capsys):
    ask(disk)
    systemd.active = False  # ended without writing a report
    assert disk.finished()["scanned_at"] is None
    assert "ended without a new report" in capsys.readouterr().out
    clock["t"] += 10
    assert ask(disk)["state"] == "idle"
    assert systemd.starts == 1


def test_a_refused_start_is_reported_without_its_detail_and_spaced_like_any_other(disk, systemd, clock):
    systemd.refuse = True
    body = ask(disk)
    assert body["error"]["code"] == "scan_unavailable"
    assert "Access denied" not in body["error"]["message"]
    assert ask(disk)["state"] == "idle"  # not asked again inside the spacing
    clock["t"] += RESCAN_S
    systemd.refuse = False
    assert ask(disk)["state"] == "scanning"


def test_finished_hands_back_the_new_report_once(disk, systemd, report, capsys):
    assert disk.finished() is None  # nothing started
    ask(disk)
    assert disk.finished() is None  # still running
    report.write_text(json.dumps(REPORT))
    systemd.active = False
    assert disk.finished()["users"] == REPORT["users"]
    assert disk.finished() is None
    assert "ended without" not in capsys.readouterr().out


def test_a_half_written_report_reads_as_none(disk, report):
    report.write_text("{")
    assert ask(disk)["scanned_at"] is None


@pytest.mark.parametrize(
    "payload", [b"[]", b'{"refresh": "yes"}', b'{"refresh": true, "path": "/"}', b"not json", b"[" * 1000]
)
def test_a_malformed_request_is_refused(disk, payload):
    assert disk.answer(payload)["error"]["code"] == "invalid_request"


def test_an_empty_body_is_a_plain_ask():
    assert parse_request(b"") is False
