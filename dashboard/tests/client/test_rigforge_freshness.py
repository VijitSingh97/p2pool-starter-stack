from datetime import UTC, datetime

from mining_dashboard.client.rigforge_freshness import feed_stale
from mining_dashboard.client.xmrig_client import parse_rigforge


def test_generation_stamp_ages_and_old_or_missing_stamps_are_not_fresh():
    payload = {"generated_at": "2026-09-07T05:00:00Z", "rigforge": {"version": "1.0.0"}}
    generated = datetime(2026, 9, 7, 5, tzinfo=UTC).timestamp()
    fresh = parse_rigforge(payload, now=generated + 30)
    stale = parse_rigforge(payload, now=generated + 61)
    legacy = parse_rigforge({"rigforge": {"version": "1.0.0"}}, now=generated + 30)
    assert (fresh["age_sec"], fresh["stale"]) == (30, False)
    assert (stale["age_sec"], stale["stale"]) == (61, True)
    assert legacy["age_sec"] is None and legacy["stale"] is True
    assert feed_stale({"stale": False}, now=generated + 30) is True
