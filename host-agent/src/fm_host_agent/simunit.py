"""The ``sim`` answer: this host's sim agent unit, and starting, stopping or restarting it.

fm-desktop's Simulation screen starts a stopped workstation sim agent from a
button, as it does a Mac's or the cloud host's. The sim agent cannot do that
for itself while it is down, so the host agent, which runs whenever the host
is up, asks systemd: ``fm-sim-agent.service`` is the one unit besides the
disk scan that the polkit rule lets this account start, stop or restart.

A query with no body, or ``{"action": "status"}``, only reads the unit. The
other actions queue the change with ``--no-block`` and answer with the state
systemd reports at once, often ``activating`` or ``deactivating``; the caller
asks again to see where it settled. A host without the unit answers
``installed: false`` and refuses every action.

tradeoff: anyone on the fabric can ask, as anyone on it can already start and
bring down runs through the sim agent's own verbs. The rule bounds what a
request can do to this unit's three verbs, and changes are spaced
``CHANGE_SPACING_S`` apart, so a held button cannot keep the unit cycling.
"""

from __future__ import annotations

import json
import subprocess
import threading
import time

from fm_host_agent.diskusers import SYSTEMCTL, SYSTEMCTL_TIMEOUT_S, error_body, log

SIM_UNIT = "fm-sim-agent.service"
ACTIONS = ("status", "start", "stop", "restart")
CHANGE_SPACING_S = 5.0


def read_unit() -> tuple[bool, str]:
    """Whether the unit file is installed, and its ActiveState."""
    result = subprocess.run(
        [SYSTEMCTL, "show", "--property=LoadState,ActiveState", SIM_UNIT],
        capture_output=True,
        text=True,
        timeout=SYSTEMCTL_TIMEOUT_S,
    )
    fields = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
    return fields.get("LoadState") == "loaded", fields.get("ActiveState", "unknown")


def change_unit(action: str) -> None:
    """Queue ``action`` on the unit and return at once; raise if systemd or polkit refuses."""
    subprocess.run(
        [SYSTEMCTL, action, "--no-block", SIM_UNIT],
        check=True,
        capture_output=True,
        timeout=SYSTEMCTL_TIMEOUT_S,
    )


def parse_request(payload: bytes | None) -> str:
    """The request's ``action``, or raise ValueError saying what is wrong with it."""
    if not payload:
        return "status"
    try:
        request = json.loads(payload)
    except RecursionError as exc:  # deeply nested, and not a ValueError
        raise ValueError("the body is nested too deeply") from exc
    if not isinstance(request, dict) or set(request) - {"action"}:
        raise ValueError('the body is {"action"?: "status" | "start" | "stop" | "restart"}')
    action = request.get("action", "status")
    if action not in ACTIONS:
        raise ValueError(f"action is one of {', '.join(ACTIONS)}")
    return action


class SimUnit:
    """Answers ``sim`` queries. ``read`` and ``change`` are systemd and ``clock``
    the monotonic one changes are spaced by; all three are replaced in tests.
    """

    def __init__(self, read=read_unit, change=change_unit, clock=time.monotonic) -> None:
        self.read = read
        self.change = change
        self.clock = clock
        self.lock = threading.Lock()
        self.changed_at: float | None = None

    def answer(self, payload: bytes | None) -> dict:
        try:
            action = parse_request(payload)
        except ValueError as exc:
            return error_body("invalid_request", str(exc))
        try:
            installed, state = self.read()
        except (OSError, subprocess.SubprocessError) as exc:
            log(f"reading {SIM_UNIT} failed: {exc}")
            return error_body("sim_unavailable", "this host could not read its sim agent unit")
        if action != "status":
            if not installed:
                return error_body("sim_unavailable", "this host has no sim agent unit")
            with self.lock:
                now = self.clock()
                if self.changed_at is not None and now - self.changed_at < CHANGE_SPACING_S:
                    return error_body("too_soon", f"the sim agent changed under {CHANGE_SPACING_S:g} s ago")
                self.changed_at = now
            try:
                self.change(action)
            except (OSError, subprocess.SubprocessError) as exc:
                log(f"{action} {SIM_UNIT} failed: {exc}")
                return error_body("sim_refused", f"this host could not {action} its sim agent")
            try:
                installed, state = self.read()
            except (OSError, subprocess.SubprocessError) as exc:
                # systemd took the change; only where it has got to is unknown.
                log(f"reading {SIM_UNIT} after {action} failed: {exc}")
                state = "unknown"
        return {"ok": True, "unit": SIM_UNIT, "installed": installed, "state": state}
