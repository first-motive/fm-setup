"""The polkit rule's grants, evaluated by node under a stub of polkit's API.

polkit runs rules in its own JavaScript engine; node runs the same file here,
so the test reads exactly what is installed. Skipped where node is missing.
"""

from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

import pytest

RULE = Path(__file__).resolve().parents[1] / "systemd" / "50-fm-host-agent.rules"
MANAGE_UNITS = "org.freedesktop.systemd1.manage-units"

HARNESS = """
const fs = require("fs");
const polkit = {Result: {YES: "yes", NOT_HANDLED: "not_handled"}, addRule(f) { this.rule = f; }};
eval(fs.readFileSync(process.argv[1], "utf8"));
const cases = JSON.parse(process.argv[2]);
console.log(JSON.stringify(cases.map(([id, unit, verb, user]) =>
  polkit.rule({id, lookup: (k) => ({unit, verb})[k]}, {user}))));
"""

CASES = [
    # (action, unit, verb, user) → result
    ((MANAGE_UNITS, "fm-sim-agent.service", "start", "fm-host"), "yes"),
    ((MANAGE_UNITS, "fm-sim-agent.service", "stop", "fm-host"), "yes"),
    ((MANAGE_UNITS, "fm-sim-agent.service", "restart", "fm-host"), "yes"),
    ((MANAGE_UNITS, "fm-host-disk-scan.service", "start", "fm-host"), "yes"),
    ((MANAGE_UNITS, "fm-sim-agent.service", "reload", "fm-host"), "not_handled"),
    ((MANAGE_UNITS, "fm-sim-agent.service", "enable", "fm-host"), "not_handled"),
    ((MANAGE_UNITS, "fm-host-disk-scan.service", "stop", "fm-host"), "not_handled"),
    ((MANAGE_UNITS, "sshd.service", "stop", "fm-host"), "not_handled"),
    ((MANAGE_UNITS, "fm-sim-agent.service", "start", "fm"), "not_handled"),
    (("org.freedesktop.login1.reboot", "fm-sim-agent.service", "start", "fm-host"), "not_handled"),
]


@pytest.mark.skipif(shutil.which("node") is None, reason="node evaluates the rule")
def test_the_rule_grants_fm_host_exactly_its_units_and_verbs():
    result = subprocess.run(
        ["node", "-e", HARNESS, str(RULE), json.dumps([list(case) for case, _ in CASES])],
        capture_output=True,
        text=True,
        check=True,
        timeout=30,
    )
    assert json.loads(result.stdout) == [expected for _, expected in CASES]
