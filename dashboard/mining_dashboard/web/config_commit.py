"""Approval preparation for a sensitive Configuration-view commit."""

from aiohttp import web


async def approval_envelope(request, body, actor):
    """Pause dashboard polling and pass only typed suffixes to the host approval gate."""
    if body.get("approve") is not True:
        return None, None
    suffixes = body.get("payout_suffixes", {})
    if not isinstance(suffixes, dict) or any(
        key not in ("monero", "tari") or not isinstance(value, str)
        for key, value in suffixes.items()
    ):
        raise ValueError("invalid payout confirmation")
    bot = request.app.get("telegram_bot")
    if bot is None or not bot.config_approval_enabled:
        return None, web.json_response(
            {"id": body.get("id"), "status": "approval-unavailable"}, status=409
        )
    if not await bot.pause_for_host_approval():
        return None, web.json_response(
            {"id": body.get("id"), "status": "approval-unavailable"}, status=409
        )
    return {"payout_suffixes": suffixes}, None
