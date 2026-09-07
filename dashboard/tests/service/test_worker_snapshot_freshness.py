from unittest.mock import MagicMock

from mining_dashboard.client.rigforge_freshness import feed_stale
from mining_dashboard.service.data_service import DataService


def test_stored_report_is_reaged_instead_of_trusting_cached_boolean():
    report = {"generated_at": "2026-01-01T00:00:00Z", "stale": False}
    assert feed_stale(report, now=1767225661) is True


def test_restored_unstamped_agent_report_fails_closed():
    state = MagicMock()
    state.load_snapshot.return_value = {
        "workers": [{"name": "rig", "rigforge": {"version": "1.2.3"}}]
    }
    service = DataService(state, MagicMock(), MagicMock())
    assert service.latest_data["workers"][0]["rigforge"]["stale"] is True
