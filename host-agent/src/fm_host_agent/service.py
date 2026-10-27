"""The agent's entry point: its Zenoh session and the command line that opens it.

Laid out as fm-sim-agent's service is. The readers live in :mod:`load`; this
opens a client-mode session against the fleet router, publishes this host's load under
``fm/host/<host>/load`` every two seconds, and serves the last reading on the
same key as a queryable, so a viewer that opens between two publishes is not
left blank.

Client mode, not peer: every byte crosses the fleet through the router on 7447,
the one port the tailnet ACL opens.

The load is read on a thread of its own, never on Zenoh's: a pass over every
process takes tens of milliseconds on a busy host, and a Zenoh callback must
not block the runtime thread that calls it. The queryable only hands back what
that thread last read.
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
from fm_host_agent.env import EndpointError, router_endpoint

KEY_PREFIX = "fm/host"
PUBLISH_PERIOD_S = 2.0


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


class Fabric:
    """Everything this agent declares on one session, kept alive together.

    ``read_load`` returns one ``load`` body; it is called once here, so the
    queryable has an answer from the first query on, then every ``period_s``.
    """

    def __init__(self, session, host: str, read_load, period_s: float = PUBLISH_PERIOD_S) -> None:
        self.session = session
        self.host = host
        self.read_load = read_load
        # Encoded once per reading, not once per viewer that asks for it.
        self.latest = encode(read_load())
        self.stop = threading.Event()
        load_key = key_of(host, "load")
        self.publisher = session.declare_publisher(load_key)
        self.queryables = [
            session.declare_queryable(load_key, lambda query: _reply_json(query, load_key, self.latest))
        ]
        self.thread = threading.Thread(target=self._publish, args=(period_s,), name="load", daemon=True)
        self.thread.start()

    def _publish(self, period_s: float) -> None:
        while not self.stop.is_set():
            try:
                self.latest = encode(self.read_load())
                self.publisher.put(self.latest)
            except Exception:  # noqa: BLE001 - one bad read must not end the publishing
                # A viewer sees the reading age and calls the host unknown; the log says why.
                log(f"reading the load failed:\n{traceback.format_exc()}")
            self.stop.wait(period_s)

    def close(self) -> None:
        self.stop.set()
        self.thread.join(timeout=5)
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


def serve(host: str, endpoint: str, read_load, wait) -> None:
    """Publish on a client session to ``endpoint`` until ``wait()`` returns."""
    import zenoh

    with zenoh.open(_session_config(endpoint)) as session:
        fabric = Fabric(session, host, read_load)
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
        serve(host, endpoint, read_load, wait=lambda: signal.sigwait(stop_signals))
    finally:
        gpus.close()
    log("stopped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
