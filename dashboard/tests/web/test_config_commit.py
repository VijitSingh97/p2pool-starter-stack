import json
import uuid

import pytest

from mining_dashboard.service import control_service
from mining_dashboard.service.storage_service import StateManager
from mining_dashboard.web.server import create_app


@pytest.fixture
def config_spool(tmp_path, monkeypatch):
    (tmp_path / "config.json").write_text(json.dumps({"p2pool": {"pool": "mini"}}))
    (tmp_path / "requests").mkdir()
    (tmp_path / "results").mkdir()
    monkeypatch.setattr(control_service.config, "DASHBOARD_CONTROL_ENABLED", True)
    monkeypatch.setattr(control_service.config, "HOST_CONFIG_PATH", str(tmp_path / "config.json"))
    monkeypatch.setattr(
        control_service.config, "HOST_REFERENCE_PATH", str(tmp_path / "no-reference.json")
    )
    monkeypatch.setattr(control_service.config, "CONTROL_REQUESTS_DIR", str(tmp_path / "requests"))
    monkeypatch.setattr(control_service.config, "CONTROL_RESULTS_DIR", str(tmp_path / "results"))
    monkeypatch.setattr(control_service.config, "CONTROL_WAIT_S", 0.1)
    return tmp_path


@pytest.fixture
async def config_client(aiohttp_client, config_spool):
    data = {"shares": [], "workers": [], "global_sync": False}
    state = StateManager(db_path=":memory:")
    client = await aiohttp_client(create_app(state, data, telegram_bot=ApprovalBot()))
    yield client
    state.close()


class ApprovalBot:
    config_approval_enabled = True

    def __init__(self):
        self.paused = False

    async def pause_for_host_approval(self):
        self.paused = True
        return True


async def test_sensitive_commit_sends_only_suffixes_and_caddy_actor_to_host(
    config_client, config_spool
):
    rid = str(uuid.uuid4())
    (config_spool / "results" / f"{rid}.json").write_text(
        json.dumps(
            {
                "status": "previewed",
                "preview_values": [
                    {
                        "key": "monero.wallet_address",
                        "old": "old-address",
                        "new": "full-new-address-12345678",
                    }
                ],
            }
        )
    )
    request = {
        "id": rid,
        "approve": True,
        "confirm": "APPLY",
        "payout_suffixes": {"monero": "12345678"},
        "actor": "forged",
    }
    headers = {"X-Pithead-Control": "1", "X-Auth-User": "real-admin"}
    resp = await config_client.post("/api/control/commit", json=request, headers=headers)
    assert resp.status == 202
    assert (await resp.json())["status"] == "pending"
    spooled = json.loads((config_spool / "requests" / f"{rid}.json").read_text())
    assert spooled["actor"] == "real-admin"
    assert spooled["approval"] == {"payout_suffixes": {"monero": "12345678"}}
    assert "approver" not in spooled["approval"]
    assert "preview_id" not in spooled["approval"]


async def test_hostile_approval_shape_is_rejected_before_spooling(config_client, config_spool):
    rid = str(uuid.uuid4())
    resp = await config_client.post(
        "/api/control/commit",
        json={"id": rid, "approve": True, "payout_suffixes": {"monero": ["not", "text"]}},
        headers={"X-Pithead-Control": "1", "X-Auth-User": "admin"},
    )
    assert resp.status == 400
    assert list((config_spool / "requests").iterdir()) == []
