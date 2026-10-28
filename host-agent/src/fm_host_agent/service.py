"""The agent's entry point: its Zenoh session and the command line that opens it.

Laid out as fm-sim-agent's service is. The readers live in :mod:`load`; this
opens a client-mode session against the fleet router, publishes this host's load under
``fm/host/<host>/load`` every thirty seconds, and serves the last reading on the
same key as a queryable, so a viewer that opens between two publishes is not
left blank. A query also wakes the load thread, so a viewer that asks (on
opening, or with Refresh) hears a fresh reading within a moment instead of
waiting out the period. It also serves ``disk-users`` (see :mod:`diskusers`), and publishes
that body on the same key when a scan it started has finished.

Client mode, not peer: every byte crosses the fleet through the router on 7447,
the one port the tailnet ACL opens.

The load is read on a thread of its own, never on Zenoh's: a pass over every
process takes tens of milliseconds on a busy host, and a Zenoh callback must
not block the runtime thread that calls it. The ``load`` queryable only hands
back what that thread last read, then sets an event the thread waits on.

``disk-users`` is answered on Zenoh's thread from what the agent already
knows. tradeoff: a query that starts a scan calls systemctl once, which returns
in milliseconds and is cut off at five seconds, at most once per five minutes.
Whether a running scan has ended is asked of systemd on a third thread, so
neither a query nor the load ever waits on it.

A refusal goes out as a Zenoh error reply carrying the ``{"ok": false, "error"}``
body, as fm-sim-agent sends its refusals.
"""

from __future__ import annotations

import argparse
import json
import signal
import sys
import threading
import traceback
from importlib.metadata import PackageNotFoundError, version

from fm_host_agent.card import CardError, host_segment, read_host
from fm_host_agent.diskusers import MAX_REQUEST_BYTES, DiskUsers, error_body
from fm_host_agent.env import EndpointError, router_endpoint

KEY_PREFIX = "fm/host"
# tradeoff: a tower's load moves slowly next to a person's glance, so 30 s keeps
# the agent and every open Devices page quiet; a viewer that wants it sooner asks.
PUBLISH_PERIOD_S = 30.0
# tradeoff: queries wake the load thread at most this often, so a burst of
# viewers (or a held Refresh) costs one process walk per 2 s, not one each.
WAKE_FLOOR_S = 2.0
# How often a running disk scan is checked for its end, apart from the load.
SCAN_POLL_S = 2.0


def log(message: str) -> None:
    print(f"fm-host-agent: {message}", flush=True)


def agent_version() -> str:
    try:
        return version("fm-host-agent")
    except PackageNotFoundError:
        return "unknown"


def key_of(host: str, name: str) -> str:
    return f"{KEY_PREFIX}/{host}/{name}"


def encode(body: dict) -> bytes:
    return json.dumps(body, sort_keys=True).encode()


def _reply_json(query, key: str, payload: bytes) -> None:
    import zenoh

    query.reply(key, payload, encoding=zenoh.Encoding.APPLICATION_JSON)


def _reply(query, key: str, body: dict) -> None:
    import zenoh

    if body.get("ok"):
        _reply_json(query, key, encode(body))
    else:
        query.reply_err(encode(body), encoding=zenoh.Encoding.APPLICATION_JSON)


def _disk_users_handler(disk_users: DiskUsers, key: str):
    def handle(query) -> None:
        # Measured before it is copied out of Zenoh: an oversized body is
        # refused without the agent ever holding it.
        if query.payload is not None and len(query.payload) > MAX_REQUEST_BYTES:
            _reply(
                query, key, error_body("invalid_request", f"body is larger than {MAX_REQUEST_BYTES} bytes")
            )
            return
        payload = query.payload.to_bytes() if query.payload is not None else None
        _reply(query, key, disk_users.answer(payload))

    return handle


class Fabric:
    """Everything this agent declares on one session, kept alive together.

    ``read_load`` returns one ``load`` body; it is called once here, so the
    queryable has an answer from the first query on, then every ``period_s``,
    or sooner when a query wakes it, but never within ``wake_floor_s`` of the
    last reading.
    """

    def __init__(
        self,
        session,
        host: str,
        read_load,
        disk_users: DiskUsers,
        period_s: float = PUBLISH_PERIOD_S,
        wake_floor_s: float = WAKE_FLOOR_S,
        scan_poll_s: float = SCAN_POLL_S,
    ) -> None:
        self.session = session
        self.host = host
        self.read_load = read_load
        self.disk_users = disk_users
        self.disk_key = key_of(host, "disk-users")
        # Encoded once per reading, not once per viewer that asks for it.
        self.latest = encode(read_load())
        self.stop = threading.Event()
        self.wake = threading.Event()
        load_key = key_of(host, "load")
        self.publisher = session.declare_publisher(load_key)
        self.queryables = [
            session.declare_queryable(load_key, self._answer_load(load_key)),
            session.declare_queryable(self.disk_key, _disk_users_handler(disk_users, self.disk_key)),
        ]
        self.threads = [
            threading.Thread(target=self._publish, args=(period_s, wake_floor_s), name="load", daemon=True),
            threading.Thread(target=self._watch_scan, args=(scan_poll_s,), name="disk-scan", daemon=True),
        ]
        for thread in self.threads:
            thread.start()

    def _answer_load(self, key: str):
        def handle(query) -> None:
            _reply_json(query, key, self.latest)
            self.wake.set()

        return handle

    def _publish(self, period_s: float, wake_floor_s: float) -> None:
        while not self.stop.is_set():
            try:
                self.latest = encode(self.read_load())
                self.publisher.put(self.latest)
            except Exception:  # noqa: BLE001 - one bad read must not end the publishing
                # A viewer sees the reading age and calls the host unknown; the log says why.
                log(f"reading the load failed:\n{traceback.format_exc()}")
            # The floor first, so a wake set during it is still heard; then the
            # rest of the period, cut short by a query.
            if self.stop.wait(wake_floor_s):
                return
            self.wake.wait(max(period_s - wake_floor_s, 0))
            self.wake.clear()

    def _watch_scan(self, poll_s: float) -> None:
        while not self.stop.is_set():
            try:
                body = self.disk_users.finished()
                if body is not None:
                    self.session.put(self.disk_key, encode(body))
            except Exception:  # noqa: BLE001 - a systemctl hiccup must not end the watching
                log(f"checking the disk scan failed:\n{traceback.format_exc()}")
            self.stop.wait(poll_s)

    def close(self) -> None:
        self.stop.set()
        self.wake.set()
        for thread in self.threads:
            thread.join(timeout=5)
        for queryable in self.queryables:
            queryable.undeclare()
        self.publisher.undeclare()


def _session_config(endpoint: str):
    """A client-mode config pointed at the fleet router.

    Imported here rather than at module scope so ``--help`` works on a host
    without the zenoh wheel.
    """
    import zenoh

    config = zenoh.Config()
    config.insert_json5("mode", json.dumps("client"))
    config.insert_json5("connect/endpoints", json.dumps([endpoint]))
    return config


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Publish this host's load over Zenoh.")
    parser.add_argument("--host", default="", help="Publish under this host name instead of the card's.")
    return parser


def serve(host: str, endpoint: str, read_load, disk_users: DiskUsers, wait) -> None:
    """Publish on a client session to ``endpoint`` until ``wait()`` returns."""
    import zenoh

    with zenoh.open(_session_config(endpoint)) as session:
        fabric = Fabric(session, host, read_load, disk_users)
        log(f"publishing {KEY_PREFIX}/{host}/* via {endpoint}")
        try:
            wait()
        finally:
            fabric.close()


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        host = host_segment(args.host) if args.host else read_host()
        endpoint = router_endpoint()
    except (CardError, EndpointError) as exc:
        print(f"fm-host-agent: {exc}", file=sys.stderr)
        return 1

    import psutil
    import pynvml

    from fm_host_agent import load

    gpus = load.Gpus(pynvml, psutil)
    log(f"{len(gpus.handles)} GPU(s) found")
    agent = agent_version()

    def read_load() -> dict:
        return load.snapshot(host, agent, psutil, gpus)

    # Blocked before the session starts its threads, so they inherit the mask
    # and the signal systemd sends on stop reaches sigwait, not a default handler.
    stop_signals = {signal.SIGINT, signal.SIGTERM}
    signal.pthread_sigmask(signal.SIG_BLOCK, stop_signals)
    try:
        serve(host, endpoint, read_load, DiskUsers(), wait=lambda: signal.sigwait(stop_signals))
    finally:
        gpus.close()
    log("stopped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
