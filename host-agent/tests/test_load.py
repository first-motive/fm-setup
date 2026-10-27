from __future__ import annotations

from fm_host_agent import load
from tests.fakes import FakeNvml, FakePs, Part, Session, Usage, gpu, proc

GIB = 2**30


def test_cpu_reads_percent_cores_and_rounded_load():
    assert load.cpu(FakePs()) == {"percent": 12.5, "cores": 32, "load": [1.23, 0.5, 0.25]}


def test_memory_counts_used_as_total_less_available():
    assert load.memory(FakePs()) == {"used": 16 * GIB, "total": 64 * GIB}


def test_mounts_skip_snaps_count_a_bind_mount_once_and_add_reserved_blocks_back():
    ps = FakePs()
    ps.partitions = [
        Part("/dev/nvme0n1p2", "/", "ext4"),
        Part("/dev/sda1", "/data", "ext4"),
        Part("/dev/sda1", "/data/bind", "ext4"),
        Part("/dev/loop3", "/snap/core/1", "squashfs"),
    ]
    ps.usage = {"/": Usage(total=100, used=90, free=5), "/data": Usage(total=1000, used=10, free=990)}
    assert load.mounts(ps) == [
        {"path": "/", "used": 90, "total": 95},
        {"path": "/data", "used": 10, "total": 1000},
    ]


def test_mounts_skip_one_that_cannot_be_statted():
    ps = FakePs()
    ps.partitions = [Part("/dev/sdb1", "/media/gone", "ext4")]
    assert load.mounts(ps) == []


def test_users_sum_login_accounts_only_and_count_their_sessions():
    ps = FakePs()
    ps.procs = [
        proc("ana", 1001, cpu=150.04, rss=3 * GIB),
        proc("ana", 1001, cpu=50.0, rss=GIB),
        proc("ben", 1002, cpu=None, rss=None),  # access denied to both
        proc("root", 0, cpu=90.0, rss=GIB),
        proc("fm-host", 998, cpu=1.0, rss=GIB),
        proc("nobody", 65534, cpu=1.0, rss=GIB),
        {"username": None, "uids": None, "cpu_percent": 1.0, "memory_info": None},
    ]
    ps.sessions = [
        Session("ana", "pts/0", "10.0.0.2", 0, 1),
        Session("ana", "pts/1", "10.0.0.2", 0, 2),
        Session("root", "tty1", "", 0, 3),
    ]
    assert load.users(ps) == [
        {"user": "ana", "cpu_percent": 200.0, "rss": 4 * GIB, "sessions": 2},
        {"user": "ben", "cpu_percent": 0.0, "rss": 0, "sessions": 0},
    ]


def test_no_driver_means_no_gpus():
    nvml = FakeNvml(absent=True)
    gpus = load.Gpus(nvml, FakePs())
    assert gpus.read() == []
    gpus.close()
    assert not nvml.shut


def test_gpu_lists_each_process_once_by_owner_and_comm():
    ps = FakePs()
    ps.by_pid = {10: ("ana", "python3"), 11: ("ben", "Xorg"), 12: FakePs.AccessDenied}
    nvml = FakeNvml([gpu(compute=[(10, 4 * GIB), (12, GIB), (13, GIB)], graphics=[(10, GIB), (11, None)])])
    gpus = load.Gpus(nvml, ps)
    assert gpus.read() == [
        {
            "index": 0,
            "name": "NVIDIA RTX 6000 Ada",
            "util": 40,
            "mem_used": 2 * GIB,
            "mem_total": 48 * GIB,
            "processes": [
                {"pid": 10, "user": "ana", "name": "python3", "mem": 4 * GIB},
                {"pid": 11, "user": "ben", "name": "Xorg", "mem": 0},
                {"pid": 12, "user": "unknown", "name": "unknown", "mem": GIB},
            ],
        }
    ]
    gpus.close()
    assert nvml.shut


def test_a_gpu_the_driver_cannot_read_drops_out_and_keeps_its_index_for_the_rest():
    gpus = load.Gpus(FakeNvml([gpu(broken=True), gpu(name="second")]), FakePs())
    assert [(row["index"], row["name"]) for row in gpus.read()] == [(1, "second")]


def test_snapshot_is_the_load_body():
    body = load.snapshot("fm_ws_01", "0.1.0", FakePs(), load.Gpus(FakeNvml(), FakePs()), now=lambda: 5.0)
    assert body["ok"] is True
    assert (body["host"], body["t"], body["version"]) == ("fm_ws_01", 5.0, "0.1.0")
    assert set(body) == {"ok", "host", "t", "version", "cpu", "memory", "gpus", "mounts", "users"}


def test_a_driver_that_cannot_count_its_gpus_reports_none_and_still_shuts_down():
    nvml = FakeNvml([gpu()])

    def no_count():
        raise nvml.NVMLError("Unknown Error")

    nvml.nvmlDeviceGetCount = no_count
    gpus = load.Gpus(nvml, FakePs())
    assert gpus.read() == []
    gpus.close()
    assert nvml.shut
