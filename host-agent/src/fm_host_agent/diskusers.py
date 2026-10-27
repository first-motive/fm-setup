"""The ``disk-users`` answer: the last scan's report, and when to start another.

The agent never walks a disk itself. Its account cannot read other accounts'
files, so it asks systemd to start ``fm-host-disk-scan.service`` — the one
unit a polkit rule lets it start — and reads the report that unit writes.

Every reply is immediate: the report on disk, as old as it is, and whether a
scan is running. A query starts a scan when the report is older than
``STALE_S`` or the caller asks for a refresh; starts, including refused ones,
are spaced ``RESCAN_S`` apart, so a viewer held on Scan Again cannot keep a
disk busy or keep polkit asked.

Whether a scan is still running is learned by :meth:`DiskUsers.finished`,
which the service calls on a thread of its own. A query reads the flag it
leaves and never waits on systemd, except to start a scan.
"""

from __future__ import annotations

import json
import subprocess
import threading
import time
from pathlib import Path

from fm_host_agent.diskscan import OUTPUT, ROOTS

SCAN_UNIT = "fm-host-disk-scan.service"
SYSTEMCTL = "/usr/bin/systemctl"
STALE_S = 15 * 60
RESCAN_S = 5 * 60
#: The service refuses a larger body before copying it out of Zenoh.
MAX_REQUEST_BYTES = 1024
SYSTEMCTL_TIMEOUT_S = 5
#: Unit states in which the scan has been started and has not finished.
RUNNING_STATES = frozenset({"activating", "active", "deactivating", "reloading"})


def log(message: str) -> None:
    print(f"fm-host-agent: {message}", flush=True)


def error_body(code: str, message: str) -> dict:
    return {"ok": False, "error": {"code": code, "message": message}}


def start_scan() -> None:
    """Queue the scan unit and return at once; raise if systemd or polkit refuses."""
    subprocess.run(
        [SYSTEMCTL, "start", "--no-block", SCAN_UNIT],
        check=True,
        capture_output=True,
        timeout=SYSTEMCTL_TIMEOUT_S,
    )


def scan_running() -> bool:
    result = subprocess.run(
        [SYSTEMCTL, "show", "--property=ActiveState", "--value", SCAN_UNIT],
        capture_output=True,
        text=True,
        timeout=SYSTEMCTL_TIMEOUT_S,
    )
    return result.stdout.strip() in RUNNING_STATES


def parse_request(payload: bytes | None) -> bool:
    """The request's ``refresh``, or raise ValueError saying what is wrong with it."""
    if not payload:
        return False
    try:
        request = json.loads(payload)
    except RecursionError as exc:  # deeply nested, and not a ValueError
        raise ValueError("the body is nested too deeply") from exc
    if not isinstance(request, dict) or set(request) - {"refresh"}:
        raise ValueError('the body is {"refresh"?: bool}')
    refresh = request.get("refresh", False)
    if not isinstance(refresh, bool):
        raise ValueError("refresh is a bool")
    return refresh


class DiskUsers:
    """Answers ``disk-users`` queries and notices when a scan it started has finished.

    ``start`` and ``running`` are systemd; ``now`` is the wall clock reports are
    stamped with, ``clock`` the monotonic one starts are spaced by. All four are
    replaced in tests.
    """

    def __init__(
        self,
        report: Path = OUTPUT,
        start=start_scan,
        running=scan_running,
        now=time.time,
        clock=time.monotonic,
    ) -> None:
        self.report = report
        self.start = start
        self.running = running
        self.now = now
        self.clock = clock
        # Held only around the fields below, never across a systemctl call.
        self.lock = threading.Lock()
        self.started_at: float | None = None
        self.scanning = False

    def read_report(self) -> dict | None:
        try:
            body = json.loads(self.report.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None  # no scan yet, or one being replaced
        return body if isinstance(body, dict) else None

    def body(self, report: dict | None, state: str) -> dict:
        report = report or {}
        return {
            "ok": True,
            "state": state,
            "scanned_at": report.get("scanned_at"),
            "roots": report.get("roots", list(ROOTS)),
            "users": report.get("users", []),
        }

    def answer(self, payload: bytes | None) -> dict:
        try:
            refresh = parse_request(payload)
        except ValueError as exc:
            return error_body("invalid_request", str(exc))
        report = self.read_report()
        with self.lock:
            if self.scanning:
                return self.body(report, "scanning")
            clock = self.clock()
            spaced = self.started_at is None or clock - self.started_at >= RESCAN_S
            if refresh and not spaced:
                wait_s = int(RESCAN_S - (clock - self.started_at))
                return error_body(
                    "too_soon", f"a scan started under {RESCAN_S // 60} minutes ago; scan again in {wait_s} s"
                )
            stale = report is None or self.now() - (report.get("scanned_at") or 0) > STALE_S
            if not spaced or not (refresh or stale):
                return self.body(report, "idle")
            self.started_at, self.scanning = clock, True
        try:
            self.start()
        except (OSError, subprocess.SubprocessError) as exc:
            log(f"starting {SCAN_UNIT} failed: {exc}")
            with self.lock:
                self.scanning = False  # started_at stays, so the next attempt waits its turn
            return error_body("scan_unavailable", "the disk scan could not be started on this host")
        return self.body(report, "scanning")

    def finished(self) -> dict | None:
        """The report once a scan this agent started has ended, else None.

        Asks systemd, so the service calls it off Zenoh's thread and off the load's.
        """
        with self.lock:
            if not self.scanning:
                return None
            started_at = self.started_at
        if self.running():
            return None
        with self.lock:
            if not self.scanning or self.started_at != started_at:
                return None  # another thread already saw it end
            self.scanning = False
        report = self.read_report()
        report_age_s = self.now() - (report.get("scanned_at") or 0) if report else None
        scan_took_s = self.clock() - started_at
        # A report this scan wrote is younger than the scan; the minute of slack
        # covers the wall and monotonic clocks drifting apart over a long scan.
        if report_age_s is None or report_age_s > scan_took_s + 60:
            # tradeoff: a scan that timed out or failed leaves the old report, and
            # the viewer sees its age; the journal says why.
            log(f"{SCAN_UNIT} ended without a new report; see journalctl -u {SCAN_UNIT}")
        return self.body(report, "idle")
