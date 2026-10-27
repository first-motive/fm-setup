"""Stand-ins for psutil and pynvml, shaped like the parts the readers touch."""

from __future__ import annotations

import subprocess
from collections import namedtuple
from types import SimpleNamespace

Part = namedtuple("Part", "device mountpoint fstype")
Usage = namedtuple("Usage", "total used free")
Uids = namedtuple("Uids", "real effective saved")
Mem = namedtuple("Mem", "rss")
Session = namedtuple("Session", "name terminal host started pid")
Vm = namedtuple("Vm", "total available")


class FakePs:
    """psutil, with every reading set by the test."""

    class Error(Exception):
        pass

    class NoSuchProcess(Error):
        pass

    class AccessDenied(Error):
        pass

    def __init__(self) -> None:
        self.percent = 12.5
        self.cores = 32
        self.loadavg = (1.234, 0.5, 0.25)
        self.vm = Vm(total=64 * 2**30, available=48 * 2**30)
        self.partitions: list[Part] = []
        self.usage: dict[str, Usage] = {}
        self.procs: list[dict] = []
        self.sessions: list[Session] = []
        #: pid → (username, name), or an exception class to raise.
        self.by_pid: dict[int, object] = {}

    def cpu_percent(self, interval=None):
        return self.percent

    def cpu_count(self):
        return self.cores

    def getloadavg(self):
        return self.loadavg

    def virtual_memory(self):
        return self.vm

    def disk_partitions(self, all=False):
        return self.partitions

    def disk_usage(self, path):
        if path not in self.usage:
            raise PermissionError(path)
        return self.usage[path]

    def process_iter(self, attrs):
        return [SimpleNamespace(info={key: proc.get(key) for key in attrs}) for proc in self.procs]

    def users(self):
        return self.sessions

    def Process(self, pid):
        entry = self.by_pid.get(pid, self.NoSuchProcess)
        if isinstance(entry, type):
            raise entry(pid)
        user, name = entry
        return SimpleNamespace(username=lambda: user, name=lambda: name)


def proc(user: str, uid: int, cpu: float | None = 0.0, rss: int | None = 0) -> dict:
    return {
        "username": user,
        "uids": Uids(uid, uid, uid),
        "cpu_percent": cpu,
        "memory_info": None if rss is None else Mem(rss),
    }


class FakeNvml:
    """pynvml over a list of GPUs; ``absent`` makes nvmlInit fail as it does with no driver."""

    class NVMLError(Exception):
        pass

    def __init__(self, gpus: list[dict] | None = None, absent: bool = False) -> None:
        self.gpus = gpus or []
        self.absent = absent
        self.shut = False

    def nvmlInit(self):
        if self.absent:
            raise self.NVMLError("NVML Shared Library Not Found")

    def nvmlShutdown(self):
        self.shut = True

    def nvmlDeviceGetCount(self):
        return len(self.gpus)

    def nvmlDeviceGetHandleByIndex(self, index):
        return self.gpus[index]

    def nvmlDeviceGetName(self, gpu):
        if gpu.get("broken"):
            raise self.NVMLError("GPU is lost")
        return gpu["name"]

    def nvmlDeviceGetUtilizationRates(self, gpu):
        return SimpleNamespace(gpu=gpu["util"])

    def nvmlDeviceGetMemoryInfo(self, gpu):
        if gpu.get("broken"):
            raise self.NVMLError("GPU is lost")
        return SimpleNamespace(used=gpu["mem_used"], total=gpu["mem_total"])

    def nvmlDeviceGetComputeRunningProcesses(self, gpu):
        return [SimpleNamespace(pid=pid, usedGpuMemory=mem) for pid, mem in gpu.get("compute", [])]

    def nvmlDeviceGetGraphicsRunningProcesses(self, gpu):
        return [SimpleNamespace(pid=pid, usedGpuMemory=mem) for pid, mem in gpu.get("graphics", [])]


def gpu(**overrides) -> dict:
    return {
        "name": "NVIDIA RTX 6000 Ada",
        "util": 40,
        "mem_used": 2 * 2**30,
        "mem_total": 48 * 2**30,
    } | overrides


class Systemd:
    """The scan unit: started on request, running until the test ends it."""

    def __init__(self) -> None:
        self.starts = 0
        self.active = False
        self.refuse = False

    def start(self) -> None:
        if self.refuse:
            raise subprocess.CalledProcessError(1, "systemctl", stderr=b"Access denied")
        self.starts += 1
        self.active = True

    def running(self) -> bool:
        return self.active
