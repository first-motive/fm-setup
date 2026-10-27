# fm-host-agent

Publishes this host's CPU, memory, GPU and disk load on the fleet fabric, and
who is using each, so fm-desktop's Devices view can tell whether a shared
machine is free without anyone opening an SSH session. `scripts/steps/93-host-agent.sh`
installs it as a systemd service on the workstation role.

```bash
uv run --extra dev pytest
```
