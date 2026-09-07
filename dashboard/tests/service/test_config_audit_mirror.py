import json
from unittest.mock import MagicMock

import mining_dashboard.service.data_service as data_module
from mining_dashboard.service.data_service import DataService
from mining_dashboard.service.storage_service import StateManager


async def test_preview_is_replaced_by_failed_commit_in_durable_history(tmp_path, monkeypatch):
    event = {
        "id": "11111111-1111-4111-8111-111111111111",
        "actor": "admin",
        "keys": "MONERO_WALLET_ADDRESS",
    }
    log = tmp_path / "control.log"
    log.write_text(
        json.dumps(
            {
                **event,
                "action": "preview",
                "status": "previewed",
                "ts": "2026-07-10T12:00:00Z",
            }
        )
        + "\n"
        + json.dumps(
            {
                **event,
                "action": "commit-approved",
                "status": "failed",
                "ts": "2026-07-10T12:00:01Z",
            }
        )
        + "\n"
    )
    monkeypatch.setattr(data_module.config, "DASHBOARD_CONTROL_ENABLED", True)
    monkeypatch.setattr(data_module.audit_service.config, "CONTROL_AUDIT_LOG", str(log))
    state = StateManager(db_path=":memory:")
    service = DataService(state, MagicMock(), MagicMock())
    try:
        await service._mirror_control_audit()
        [stored] = state.get_audit_events()
        assert stored["action"] == "commit-approved"
        assert stored["status"] == "failed"
        assert stored["actor"] == "admin"
    finally:
        state.close()
