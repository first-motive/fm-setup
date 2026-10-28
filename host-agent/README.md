# fm-host-agent

Publishes this host's CPU, memory, GPU and disk load on the fleet fabric, and
who is using each, so fm-desktop's Devices view can tell whether a shared
machine is free without anyone opening an SSH session. The workstation role
installs it through `scripts/steps/93-host-agent.sh`; the keys it serves and
its privilege model are in the repo README's [Host Agent](../README.md#host-agent)
section.

## Layout

```
service.py     the Zenoh session: publishes load, serves load, disk-users and sim
  ├─ load.py       readers over psutil and NVML, one load body per call
  ├─ diskusers.py  the disk-users answer; starts the scan unit, watches it end
  ├─ simunit.py    the sim answer; reads, starts, stops or restarts fm-sim-agent.service
  ├─ card.py       this host's key segment, from /etc/fm/machine.json
  └─ env.py        the router endpoint, from /etc/fm-comms.env
diskscan.py    run as root by fm-host-disk-scan.service; writes the report
systemd/       the two units and the polkit rule, installed as they are
```

Three threads, so the load and the scan watch never wait on a query. A
`disk-users` query that starts a scan waits on `systemctl start --no-block`, for
at most 5 seconds:

```
load thread       read load (tens of ms) → publish → sleep 30 s; a load query wakes it, at most once per 2 s
disk-scan thread  scan started? → systemctl show → ended? publish disk-users
zenoh thread      load query → last bytes, wake load thread · disk-users query → answer from state
                  · sim query → systemctl show, and for a change systemctl --no-block (5 s cut-off each)
```

## Develop

```bash
uv run --extra dev pytest
uv run --extra dev ruff check . && uv run --extra dev ruff format --check .
FM_ROUTER_ENDPOINT=tcp/<router>:7447 uv run fm-host-agent --host fm-ws-01   # by hand
```
