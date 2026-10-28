from __future__ import annotations

import json
import subprocess

import pytest

from fm_host_agent.simunit import CHANGE_SPACING_S, SIM_UNIT, SimUnit, parse_request, read_unit
from tests.fakes import SimSystemd


@pytest.fixture
def systemd():
    return SimSystemd()


@pytest.fixture
def clock():
    return {"t": 100.0}


@pytest.fixture
def unit(systemd, clock):
    return SimUnit(read=systemd.read, change=systemd.change, clock=lambda: clock["t"])


def ask(unit, **request) -> dict:
    return unit.answer(json.dumps(request).encode() if request else None)


def test_no_body_reads_the_unit_and_changes_nothing(unit, systemd):
    assert ask(unit) == {"ok": True, "unit": SIM_UNIT, "installed": True, "state": "inactive"}
    assert systemd.changes == []


@pytest.mark.parametrize(
    ("action", "state"), [("start", "active"), ("restart", "active"), ("stop", "inactive")]
)
def test_an_action_queues_it_and_answers_the_new_state(unit, systemd, action, state):
    assert ask(unit, action=action)["state"] == state
    assert systemd.changes == [action]


def test_a_host_without_the_unit_says_so_and_refuses_changes(systemd):
    unit = SimUnit(read=SimSystemd(installed=False).read, change=systemd.change)
    assert ask(unit)["installed"] is False
    assert ask(unit, action="start")["error"]["code"] == "sim_unavailable"
    assert systemd.changes == []


def test_changes_are_spaced_and_status_is_not(unit, systemd, clock):
    ask(unit, action="start")
    assert ask(unit, action="restart")["error"]["code"] == "too_soon"
    assert ask(unit)["ok"] is True
    clock["t"] += CHANGE_SPACING_S
    assert ask(unit, action="restart")["state"] == "active"
    assert systemd.changes == ["start", "restart"]


def test_a_refused_change_is_an_error(unit, systemd):
    systemd.refuse = True
    body = ask(unit, action="stop")
    assert body == {
        "ok": False,
        "error": {"code": "sim_refused", "message": "this host could not stop its sim agent"},
    }


def test_a_change_systemd_took_reads_unknown_when_the_reread_fails(unit, systemd):
    reads = iter([(True, "active")])

    def read():
        try:
            return next(reads)
        except StopIteration:
            raise subprocess.TimeoutExpired("systemctl", 5) from None

    unit.read = read
    assert ask(unit, action="stop") == {"ok": True, "unit": SIM_UNIT, "installed": True, "state": "unknown"}
    assert systemd.changes == ["stop"]


def test_an_unreadable_unit_is_an_error(unit, systemd):
    systemd.unreadable = True
    assert ask(unit)["error"]["code"] == "sim_unavailable"


@pytest.mark.parametrize(
    "payload",
    [
        b"[]",
        b'{"action": "rm -rf"}',
        b'{"action": "start", "unit": "sshd.service"}',
        b"{",
        b"[" * 10_000 + b"]" * 10_000,
    ],
)
def test_anything_but_a_known_action_is_refused(payload):
    with pytest.raises(ValueError):
        parse_request(payload)


def test_read_unit_parses_systemctl_show(monkeypatch):
    def run(argv, **_):
        assert argv[-1] == SIM_UNIT
        return subprocess.CompletedProcess(argv, 0, stdout="LoadState=loaded\nActiveState=activating\n")

    monkeypatch.setattr(subprocess, "run", run)
    assert read_unit() == (True, "activating")


def test_read_unit_reads_a_missing_unit_as_not_installed(monkeypatch):
    def run(argv, **_):
        return subprocess.CompletedProcess(argv, 0, stdout="LoadState=not-found\nActiveState=inactive\n")

    monkeypatch.setattr(subprocess, "run", run)
    assert read_unit() == (False, "inactive")
