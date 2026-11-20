"""The ``sim`` and ``twin`` answers: one systemd unit each, and starting, stopping or restarting it.

fm-desktop's Simulation screen starts a stopped workstation sim agent from a
button, as it does a Mac's or the cloud host's. The sim agent cannot do that
for itself while it is down, so the host agent, which runs whenever the host
is up, asks systemd. Its robot view does the same for a robot's twin,
``fm-twin-robot@<robot>.service``, which the twin step installs and never
enables. The polkit rule lets this account start, stop or restart exactly those
units, besides starting the disk scan.

``sim`` takes ``{"action"?}`` and ``twin`` takes ``{"action"?, "robot"}``, the
robot a fleet name the rule's pattern also matches. A query with no action, or
``"status"``, only reads the unit. The other actions queue the change with
``--no-block`` and answer with the state systemd reports at once, often
``activating`` or ``deactivating``; the caller asks again to see where it
settled. A host without the unit answers ``installed: false`` and refuses every
action.

tradeoff: anyone on the fabric can ask, as anyone on it can already start and
bring down runs through the sim agent's own verbs. The rule bounds what a
request can do to these units' three verbs, and changes to one unit are spaced
``CHANGE_SPACING_S`` apart, so a held button cannot keep it cycling.
"""

from __future__ import annotations

import json
import re
import subprocess
import threading
import time
from dataclasses import dataclass

from fm_host_agent.diskusers import SYSTEMCTL, SYSTEMCTL_TIMEOUT_S, error_body, log

SIM_UNIT = "fm-sim-agent.service"
TWIN_UNIT_TEMPLATE = "fm-twin-robot@{robot}.service"
#: A robot's fleet name, as the polkit rule matches its twin unit. ASCII only, so
#: a Unicode digit cannot pass here and then fail the rule.
ROBOT_NAME = re.compile(r"fm-rob-[0-9]+", re.ASCII)
ACTIONS = ("status", "start", "stop", "restart")
CHANGE_SPACING_S = 5.0


@dataclass(frozen=True)
class Request:
    """One parsed query: what to do, to which unit, and how a message names it."""

    action: str
    unit: str
    subject: str


def read_unit(unit: str) -> tuple[bool, str]:
    """Whether the unit file is installed, and its ActiveState."""
    result = subprocess.run(
        [SYSTEMCTL, "show", "--property=LoadState,ActiveState", unit],
        capture_output=True,
        text=True,
        timeout=SYSTEMCTL_TIMEOUT_S,
    )
    fields = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
    return fields.get("LoadState") == "loaded", fields.get("ActiveState", "unknown")


def change_unit(action: str, unit: str) -> None:
    """Queue ``action`` on the unit and return at once; raise if systemd or polkit refuses."""
    subprocess.run(
        [SYSTEMCTL, action, "--no-block", unit],
        check=True,
        capture_output=True,
        timeout=SYSTEMCTL_TIMEOUT_S,
    )


def _request_body(payload: bytes | None, keys: set[str], shape: str) -> dict:
    """The body as a dict holding only ``keys``, with a known action, or raise ValueError."""
    if not payload:
        return {}
    try:
        request = json.loads(payload)
    except RecursionError as exc:  # deeply nested, and not a ValueError
        raise ValueError("the body is nested too deeply") from exc
    if not isinstance(request, dict) or set(request) - keys:
        raise ValueError(f"the body is {shape}")
    if request.get("action", "status") not in ACTIONS:
        raise ValueError(f"action is one of {', '.join(ACTIONS)}")
    return request


def parse_sim_request(payload: bytes | None) -> Request:
    """A ``sim`` query, or raise ValueError saying what is wrong with it."""
    request = _request_body(payload, {"action"}, '{"action"?: "status" | "start" | "stop" | "restart"}')
    return Request(request.get("action", "status"), SIM_UNIT, "its sim agent")


def parse_twin_request(payload: bytes | None) -> Request:
    """A ``twin`` query, or raise ValueError saying what is wrong with it."""
    shape = '{"action"?: "status" | "start" | "stop" | "restart", "robot": "fm-rob-<n>"}'
    request = _request_body(payload, {"action", "robot"}, shape)
    robot = request.get("robot")
    # Checked before it is spliced into a unit name: the name is all systemd and
    # polkit see, so nothing but a fleet robot's may reach them.
    if not isinstance(robot, str) or not ROBOT_NAME.fullmatch(robot):
        raise ValueError('robot is a robot\'s fleet name, such as "fm-rob-02"')
    return Request(
        request.get("action", "status"), TWIN_UNIT_TEMPLATE.format(robot=robot), f"the twin for {robot}"
    )


class UnitControl:
    """Answers queries about the units ``parse`` names. ``name`` prefixes the
    error codes. ``read`` and ``change`` are systemd and ``clock`` the monotonic
    one changes are spaced by; all three are replaced in tests.
    """

    def __init__(self, name: str, parse, read=read_unit, change=change_unit, clock=time.monotonic) -> None:
        self.name = name
        self.parse = parse
        self.read = read
        self.change = change
        self.clock = clock
        self.lock = threading.Lock()
        self.changed_at: dict[str, float] = {}

    def answer(self, payload: bytes | None) -> dict:
        try:
            request = self.parse(payload)
        except ValueError as exc:
            return error_body("invalid_request", str(exc))
        action, unit = request.action, request.unit
        unavailable, refused = f"{self.name}_unavailable", f"{self.name}_refused"
        try:
            installed, state = self.read(unit)
        except (OSError, subprocess.SubprocessError) as exc:
            log(f"reading {unit} failed: {exc}")
            return error_body(unavailable, f"this host could not read the unit for {request.subject}")
        if action != "status":
            if not installed:
                return error_body(unavailable, f"this host has no unit for {request.subject}")
            with self.lock:
                now = self.clock()
                last = self.changed_at.get(unit)
                if last is not None and now - last < CHANGE_SPACING_S:
                    return error_body("too_soon", f"{unit} changed under {CHANGE_SPACING_S:g} s ago")
                self.changed_at[unit] = now
            try:
                self.change(action, unit)
            except (OSError, subprocess.SubprocessError) as exc:
                log(f"{action} {unit} failed: {exc}")
                return error_body(refused, f"this host could not {action} {request.subject}")
            try:
                installed, state = self.read(unit)
            except (OSError, subprocess.SubprocessError) as exc:
                # systemd took the change; only where it has got to is unknown.
                log(f"reading {unit} after {action} failed: {exc}")
                state = "unknown"
        return {"ok": True, "unit": unit, "installed": installed, "state": state}


def sim_control(**systemd) -> UnitControl:
    """The ``sim`` answer: this host's sim agent unit."""
    return UnitControl("sim", parse_sim_request, **systemd)


def twin_control(**systemd) -> UnitControl:
    """The ``twin`` answer: the robot twin unit for the robot a query names."""
    return UnitControl("twin", parse_twin_request, **systemd)
