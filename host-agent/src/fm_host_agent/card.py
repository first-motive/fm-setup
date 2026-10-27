"""This host's name, read from its identity card.

fm-sim-agent's ``card.py``, cut to what this agent needs: the card ``fm machine
init`` writes, found at ``FM_MACHINE_FILE`` or ``/etc/fm/machine.json``, and its
name turned into the key segment every agent on the fabric derives from it.

tradeoff: the third copy of this reader (fm-robot-agent, fm-sim-agent, here).
Kept a copy on purpose: each agent lives in its own repo with its own release,
so a shared package is a new cross-repo dependency, left as its own change.
"""

from __future__ import annotations

import json
import os
import re
from pathlib import Path

SCHEMA_VERSION = 1
ENV_OVERRIDE = "FM_MACHINE_FILE"
LINUX_PATH = Path("/etc/fm/machine.json")
#: fm-sim-agent's host segment, matched whole so a trailing newline is not a name.
SEGMENT_PATTERN = re.compile(r"[a-z][a-z0-9_]*")
SEGMENT_MAX_LEN = 64


class CardError(Exception):
    """This host's card is absent, unreadable, or names no usable host."""


def card_path() -> Path:
    override = os.environ.get(ENV_OVERRIDE, "").strip()
    return Path(override).expanduser() if override else LINUX_PATH


def host_segment(name: str) -> str:
    """The key segment a machine name derives (``fm-ws-01`` → ``fm_ws_01``), or raise.

    The segment sits inside a key expression, where ``*`` and ``/`` are syntax:
    a name carrying either would publish over every host's load.
    """
    segment = name.replace("-", "_")
    if len(segment) > SEGMENT_MAX_LEN or not SEGMENT_PATTERN.fullmatch(segment):
        raise CardError(f"host name {name!r} does not derive a valid key segment")
    return segment


def read_host(path: Path | None = None) -> str:
    """This host's key segment, or raise :class:`CardError` explaining why not."""
    path = path or card_path()
    if not path.is_file():
        raise CardError(f"{path} is missing or not a file; run `fm machine init` on this host or pass --host")
    try:
        card = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise CardError(f"{path} is not readable as JSON: {exc}") from exc
    if not isinstance(card, dict):
        raise CardError(f"{path} is not a machine identity card")
    if card.get("schema_version") != SCHEMA_VERSION:
        raise CardError(
            f"{path} is schema_version {card.get('schema_version')!r}; this build reads {SCHEMA_VERSION}"
        )
    name = card.get("name")
    if not isinstance(name, str) or not name:
        raise CardError(f"{path} has no name")
    return host_segment(name)
