"""The load key over a real Zenoh session pair on localhost.

Two peer sessions in one process, joined over TCP on 127.0.0.1 with scouting
off, so nothing leaves the machine and no router is needed, as fm-sim-agent's
service tests do it. The service side is the same :class:`Fabric` ``main`` declares.
"""

from __future__ import annotations

import json
import socket
import subprocess
import sys
import time
from types import SimpleNamespace

import pytest
import zenoh

from fm_host_agent.diskusers import MAX_REQUEST_BYTES, DiskUsers
from fm_host_agent.service import Fabric, key_of, main
from tests.fakes import Systemd

HOST = "fm_ws_01"
TIMEOUT_S = 5.0


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def peer(listen: str | None = None, connect: str | None = None) -> zenoh.Session:
    config = zenoh.Config()
    config.insert_json5("mode", json.dumps("peer"))
    config.insert_json5("scouting/multicast/enabled", "false")
    config.insert_json5("listen/endpoints", json.dumps([listen] if listen else []))
    config.insert_json5("connect/endpoints", json.dumps([connect] if connect else []))
    return zenoh.open(config)


def wait_for(predicate, timeout_s: float = TIMEOUT_S) -> None:
    deadline = time.monotonic() + timeout_s
    while not predicate():
        if time.monotonic() > deadline:
            raise AssertionError("condition never held")
        time.sleep(0.01)


def get_load(client) -> list[dict]:
    return [
        json.loads(reply.ok.payload.to_bytes())
        for reply in client.get(key_of(HOST, "load"), timeout=1.0)
        if reply.ok
    ]


class Readings:
    """A ``read_load`` that counts its calls and can be told to fail."""

    def __init__(self) -> None:
        self.calls = 0
        self.fail = False

    def __call__(self) -> dict:
        if self.fail:
            raise RuntimeError("psutil fell over")
        self.calls += 1
        return {"ok": True, "host": HOST, "n": self.calls}


def get_disk_users(client, payload: bytes | None = None) -> list[tuple[bool, dict]]:
    replies = []
    for reply in client.get(key_of(HOST, "disk-users"), payload=payload, timeout=1.0):
        sample = reply.ok if reply.ok is not None else reply.err
        replies.append((reply.ok is not None, json.loads(sample.payload.to_bytes())))
    return replies


@pytest.fixture
def wire(tmp_path):
    endpoint = f"tcp/127.0.0.1:{free_port()}"
    server, client = peer(listen=endpoint), peer(connect=endpoint)
    readings, systemd = Readings(), Systemd()
    report = tmp_path / "disk-users.json"
    disk_users = DiskUsers(report, start=systemd.start, running=systemd.running)
    fabric = Fabric(server, HOST, readings, disk_users, period_s=0.05)
    # The two sessions find each other asynchronously; an answer is the signal the route is up.
    wait_for(lambda: bool(get_load(client)), timeout_s=10)
    try:
        yield SimpleNamespace(client=client, readings=readings, systemd=systemd, report=report)
    finally:
        fabric.close()
        client.close()
        server.close()


def test_the_queryable_answers_with_the_latest_reading(wire):
    client, readings = wire.client, wire.readings
    wait_for(lambda: readings.calls >= 3)
    assert get_load(client)[0]["n"] >= 3


def test_the_load_is_published_on_its_period(wire):
    client = wire.client
    seen = []
    subscriber = client.declare_subscriber(key_of(HOST, "load"), lambda sample: seen.append(sample))
    try:
        wait_for(lambda: len(seen) >= 2)
    finally:
        subscriber.undeclare()
    assert str(seen[0].key_expr) == "fm/host/fm_ws_01/load"
    assert json.loads(seen[0].payload.to_bytes())["host"] == HOST


def test_a_failed_reading_keeps_the_last_and_publishing_resumes(wire):
    client, readings = wire.client, wire.readings
    readings.fail = True
    before = readings.calls
    time.sleep(0.2)
    assert get_load(client)[0]["n"] == before
    readings.fail = False
    wait_for(lambda: readings.calls > before)


def test_disk_users_answers_and_a_refusal_is_an_error_reply(wire):
    [(ok, body)] = get_disk_users(wire.client)
    assert ok and body["state"] == "scanning"
    wire.systemd.active = False
    wait_for(lambda: get_disk_users(wire.client)[0][1]["state"] == "idle")
    [(ok, body)] = get_disk_users(wire.client, json.dumps({"refresh": True}).encode())
    assert not ok and body["error"]["code"] == "too_soon"


def test_an_oversized_disk_users_body_is_refused(wire):
    [(ok, body)] = get_disk_users(wire.client, b" " * (MAX_REQUEST_BYTES + 1))
    assert not ok and body["error"]["code"] == "invalid_request"


def test_a_finished_scan_is_published_on_the_disk_users_key(wire):
    seen = []
    subscriber = wire.client.declare_subscriber(
        key_of(HOST, "disk-users"), lambda sample: seen.append(sample)
    )
    try:
        get_disk_users(wire.client)
        wire.report.write_text(json.dumps({"scanned_at": 9.0, "roots": ["/data"], "users": []}))
        wire.systemd.active = False
        wait_for(lambda: bool(seen))
    finally:
        subscriber.undeclare()
    body = json.loads(seen[0].payload.to_bytes())
    assert (body["state"], body["scanned_at"]) == ("idle", 9.0)


def test_the_host_flag_is_checked_like_the_card(capsys):
    assert main(["--host", "fm/*"]) == 1
    assert "valid key segment" in capsys.readouterr().err


def test_no_router_is_an_error_not_a_hang(monkeypatch, tmp_path, capsys):
    monkeypatch.delenv("FM_ROUTER_ENDPOINT", raising=False)
    monkeypatch.setenv("FM_COMMS_ENV_FILE", str(tmp_path / "absent.env"))
    assert main(["--host", "fm-ws-01"]) == 1
    assert "FM_ROUTER_ENDPOINT" in capsys.readouterr().err


def test_help_needs_no_zenoh():
    """The parser builds without the wheel: nothing imports zenoh until a session opens."""
    probe = "import sys; import fm_host_agent.service as s; s.build_parser(); print('zenoh' in sys.modules)"
    result = subprocess.run([sys.executable, "-c", probe], capture_output=True, text=True, check=True)
    assert result.stdout.strip() == "False"
