import json

import pytest

from mining_dashboard.client import xmrig_client as xc
from mining_dashboard.client.xmrig_client import XMRigWorkerClient
from mining_dashboard.config import config as cfg
from mining_dashboard.config.worker_endpoints import load_worker_endpoints
from tests.client.test_xmrig_client import FakeResponse, FakeSession


def _write(path, value):
    path.write_text(json.dumps(value))


def _descriptor(host="10.0.0.5"):
    return {"workers": {"list": [{"name": "rig1", "host": host, "token": {"__secret__": True}}]}}


def _read_map(host="10.0.0.5"):
    return [{"name": "rig1", "host": host, "read_token": "a" * 64}]


def test_read_map_joins_only_valid_pinned_masked_descriptor(tmp_path):
    config_path, read_path = tmp_path / "config.json", tmp_path / "worker-read-tokens.json"
    _write(config_path, _descriptor())
    _write(read_path, _read_map())
    assert load_worker_endpoints(str(config_path), str(read_path))[0]["read_token"] == "a" * 64
    read_path.write_text("not json")
    assert "read_token" not in load_worker_endpoints(str(config_path), str(read_path))[0]


def test_stale_read_map_is_not_attached_to_replaced_host(tmp_path):
    config_path, read_path = tmp_path / "config.json", tmp_path / "worker-read-tokens.json"
    _write(config_path, _descriptor("10.0.0.6"))
    _write(read_path, _read_map())
    assert "read_token" not in load_worker_endpoints(str(config_path), str(read_path))[0]


@pytest.mark.asyncio
async def test_stale_read_map_never_sends_credential_to_replaced_host(tmp_path, monkeypatch):
    config_path, read_path = tmp_path / "config.json", tmp_path / "worker-read-tokens.json"
    _write(config_path, _descriptor("10.0.0.6"))
    _write(read_path, _read_map())
    monkeypatch.setattr(cfg, "HOST_CONFIG_PATH", str(config_path))
    monkeypatch.setattr(cfg, "WORKER_READ_TOKENS_PATH", str(read_path))
    monkeypatch.setattr(cfg, "DASHBOARD_WORKERS", None)
    monkeypatch.setattr(xc, "WORKER_ENDPOINTS", None)
    session = FakeSession(response=FakeResponse(200, {"ok": True}))
    assert (await XMRigWorkerClient(session).get_stats("10.0.0.6", "rig1"))["api_ok"] is False
    assert session.calls == []


@pytest.mark.asyncio
async def test_masked_control_token_uses_only_derived_read_bearer(monkeypatch):
    monkeypatch.setattr(xc, "XMRIG_API_AUTH", "name")
    endpoint = _descriptor()["workers"]["list"][0] | {"read_token": "a" * 64}
    monkeypatch.setattr(xc, "WORKER_ENDPOINTS", [endpoint])
    session = FakeSession(response=FakeResponse(200, {"ok": True}))
    await XMRigWorkerClient(session).get_stats("10.0.0.5", "rig1")
    assert session.calls[0][1]["Authorization"] == "Bearer " + "a" * 64


@pytest.mark.asyncio
async def test_masked_control_token_without_read_map_fails_closed(monkeypatch):
    monkeypatch.setattr(xc, "XMRIG_API_AUTH", "name")
    monkeypatch.setattr(xc, "WORKER_ENDPOINTS", _descriptor()["workers"]["list"])
    session = FakeSession(response=FakeResponse(200, {"ok": True}))
    assert await XMRigWorkerClient(session).get_stats("10.0.0.5", "rig1") == {
        "api_ok": False,
        "adopted": True,
    }
    assert session.calls == []
