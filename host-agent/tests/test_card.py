from __future__ import annotations

import json

import pytest

from fm_host_agent.card import CardError, read_host


def card(tmp_path, **fields):
    path = tmp_path / "machine.json"
    path.write_text(json.dumps({"schema_version": 1, "role": "workstation", **fields}))
    return path


def test_the_host_segment_derives_from_the_name(tmp_path):
    assert read_host(card(tmp_path, name="fm-ws-01")) == "fm_ws_01"


def test_the_override_names_the_card(tmp_path, monkeypatch):
    monkeypatch.setenv("FM_MACHINE_FILE", str(card(tmp_path, name="fm-ws-02")))
    assert read_host() == "fm_ws_02"


@pytest.mark.parametrize("name", ["fm/*", "FM-WS-01", "", "1host", "a" * 65])
def test_a_name_that_is_not_a_key_segment_is_refused(tmp_path, name):
    with pytest.raises(CardError):
        read_host(card(tmp_path, name=name))


def test_an_absent_card_says_how_to_fix_it(tmp_path):
    with pytest.raises(CardError, match="--host"):
        read_host(tmp_path / "missing.json")


def test_another_schema_version_is_refused(tmp_path):
    with pytest.raises(CardError, match="schema_version"):
        read_host(card(tmp_path, name="fm-ws-01", schema_version=2))
