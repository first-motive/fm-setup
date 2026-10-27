"""This host's load, read from the kernel and the GPU driver.

Readers only: nothing here touches the fabric or writes a file, and the one
thing held open is the NVML handle :class:`Gpus` owns. Each reader takes the
module it reads from — psutil, or pynvml for the GPUs — so the tests hand it a
fake instead of a machine.

What a reader may say about another account's process is bounded on purpose.
The fabric is fleet-wide, so a process is named by its ``comm`` (psutil's
``name()``) and never by its command line, whose arguments can carry tokens.
"""

from __future__ import annotations

import time

#: Login accounts start here on Ubuntu; system accounts (fm-host, fm-sim, the
#: daemons) sit below it and are not who anyone is asking about.
LOGIN_UID_MIN = 1000
NOBODY_UID = 65534

#: Filesystems that are real devices to the kernel but hold nothing anyone
#: fills: each snap is a read-only squashfs on a loop device.
SKIPPED_FSTYPES = frozenset({"squashfs"})


def is_login_uid(uid: int) -> bool:
    return uid >= LOGIN_UID_MIN and uid != NOBODY_UID


def cpu(ps) -> dict:
    """Whole-machine CPU use since the previous call (0.0 on the first)."""
    return {
        "percent": ps.cpu_percent(interval=None),
        "cores": ps.cpu_count(),
        "load": [round(value, 2) for value in ps.getloadavg()],
    }


def memory(ps) -> dict:
    """Used is what the kernel could not hand out now: total less available, as ``free -h`` counts it."""
    vm = ps.virtual_memory()
    return {"used": vm.total - vm.available, "total": vm.total}


def mounts(ps) -> list[dict]:
    """One row per real filesystem, a device mounted twice (a bind mount) counted once.

    ``total`` is used plus free-to-users, not the raw size: the root-reserved
    blocks are space nobody but root can fill, so this ratio is ``df``'s Use%
    and a full disk reads as 100%.
    """
    rows, seen = [], set()
    # Shortest path first, so a device mounted twice is reported at its parent mount.
    for part in sorted(ps.disk_partitions(all=False), key=lambda p: len(p.mountpoint)):
        if part.fstype in SKIPPED_FSTYPES or part.device in seen:
            continue
        seen.add(part.device)
        try:
            usage = ps.disk_usage(part.mountpoint)
        except OSError:
            continue  # unmounted between the two calls, or not ours to stat
        rows.append({"path": part.mountpoint, "used": usage.used, "total": usage.used + usage.free})
    return sorted(rows, key=lambda row: row["path"])


def users(ps) -> list[dict]:
    """CPU, resident memory and login sessions, summed per login account.

    ``process_iter`` keeps each process's handle between calls, so a process's
    ``cpu_percent`` is its use since the previous call, as the machine's is.
    """
    rows: dict[str, dict] = {}
    for proc in ps.process_iter(["uids", "username", "memory_info", "cpu_percent"]):
        info = proc.info
        name, uids = info["username"], info["uids"]
        if not name or uids is None or not is_login_uid(uids.real):
            continue
        row = rows.setdefault(name, {"user": name, "cpu_percent": 0.0, "rss": 0, "sessions": 0})
        row["cpu_percent"] += info["cpu_percent"] or 0.0
        row["rss"] += info["memory_info"].rss if info["memory_info"] else 0
    for session in ps.users():
        if session.name in rows:
            rows[session.name]["sessions"] += 1
    for row in rows.values():
        row["cpu_percent"] = round(row["cpu_percent"], 1)
    return sorted(rows.values(), key=lambda row: row["user"])


class Gpus:
    """NVML, opened once. A host with no NVIDIA driver has no GPUs, not an error."""

    def __init__(self, nvml, ps) -> None:
        self.nvml = nvml
        self.ps = ps
        self.handles = []
        try:
            nvml.nvmlInit()
        except nvml.NVMLError:
            self.opened = False
            return
        self.opened = True
        try:
            self.handles = [nvml.nvmlDeviceGetHandleByIndex(i) for i in range(nvml.nvmlDeviceGetCount())]
        except nvml.NVMLError:
            pass  # a driver that loads but cannot count its GPUs reports none

    def read(self) -> list[dict]:
        rows = []
        for index, handle in enumerate(self.handles):
            try:
                rows.append(self._device(index, handle))
            except self.nvml.NVMLError:
                continue  # tradeoff: a GPU the driver cannot read drops out of the list rather than failing the rest
        return rows

    def _device(self, index: int, handle) -> dict:
        nvml = self.nvml
        mem = nvml.nvmlDeviceGetMemoryInfo(handle)
        return {
            "index": index,
            "name": nvml.nvmlDeviceGetName(handle),
            "util": nvml.nvmlDeviceGetUtilizationRates(handle).gpu,
            "mem_used": mem.used,
            "mem_total": mem.total,
            "processes": self._processes(handle),
        }

    def _processes(self, handle) -> list[dict]:
        nvml = self.nvml
        held: dict[int, int] = {}
        # A process doing both compute and graphics is listed by both calls.
        compute = nvml.nvmlDeviceGetComputeRunningProcesses(handle)
        graphics = nvml.nvmlDeviceGetGraphicsRunningProcesses(handle)
        for proc in compute + graphics:
            held[proc.pid] = max(held.get(proc.pid, 0), proc.usedGpuMemory or 0)
        rows = []
        for pid, mem in sorted(held.items()):
            try:
                process = self.ps.Process(pid)
                user, name = process.username(), process.name()
            except self.ps.NoSuchProcess:
                continue  # exited since NVML listed it, and holds nothing now
            except self.ps.Error:
                user = name = "unknown"
            rows.append({"pid": pid, "user": user, "name": name, "mem": mem})
        return rows

    def close(self) -> None:
        if self.opened:
            self.nvml.nvmlShutdown()


def snapshot(host: str, version: str, ps, gpus: Gpus, now=time.time) -> dict:
    """The ``fm/host/<host>/load`` body."""
    return {
        "ok": True,
        "host": host,
        "t": now(),
        "version": version,
        "cpu": cpu(ps),
        "memory": memory(ps),
        "gpus": gpus.read(),
        "mounts": mounts(ps),
        "users": users(ps),
    }
