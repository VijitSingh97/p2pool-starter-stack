"""Freshness contract for RigForge's generated sister feed."""

import time
from datetime import UTC, datetime

STALE_AFTER_S = 60


def feed_age(stamp, now=None) -> int | None:
    """Return age in seconds, or None when the UTC stamp cannot prove freshness."""
    try:
        generated = datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC).timestamp()
        age = (time.time() if now is None else now) - generated
        return max(0, round(age)) if age >= -STALE_AFTER_S else None
    except (TypeError, ValueError):
        return None


def feed_stale(report, now=None) -> bool:
    """Re-age a stored report; missing or invalid producer stamps fail closed."""
    if not isinstance(report, dict):
        return True
    age = feed_age(report.get("generated_at"), now)
    return age is None or age > STALE_AFTER_S
