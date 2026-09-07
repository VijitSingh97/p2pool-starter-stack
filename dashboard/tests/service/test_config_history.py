from mining_dashboard.service.storage_service import StateManager


def test_terminal_control_outcome_replaces_preview_with_the_same_id():
    state = StateManager(db_path=":memory:")
    try:
        state.add_audit_event(
            id="same",
            ts="2026-07-20T12:00:00Z",
            source="control",
            actor="admin",
            action="preview",
            status="previewed",
            keys="MONERO_WALLET_ADDRESS",
        )
        state.add_audit_event(
            id="same",
            ts="2026-07-20T12:00:01Z",
            source="control",
            actor="admin",
            action="commit-approved",
            status="failed",
            keys="MONERO_WALLET_ADDRESS",
        )
        assert state.get_audit_events() == [
            {
                "id": "same",
                "ts": "2026-07-20T12:00:01Z",
                "source": "control",
                "actor": "admin",
                "action": "commit-approved",
                "status": "failed",
                "keys": "MONERO_WALLET_ADDRESS",
            }
        ]
    finally:
        state.close()
