"""Approval preparation for a sensitive Configuration-view commit."""

import asyncio

from aiohttp import web

from mining_dashboard.service import control_service


async def approval_envelope(request, body, actor):
    """Return ``(envelope, pending_response)`` after validating the second identity."""
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
    approval = bot.take_config_approval(body.get("id"), actor, suffixes)
    if approval is not None:
        return approval, None
    preview = await control_service.wait_result(body.get("id"))
    if not preview or preview.get("status") != "previewed":
        raise ValueError("preview is not available")
    await asyncio.to_thread(
        bot.request_config_approval,
        body.get("id"),
        actor,
        suffixes,
        preview.get("preview_values", []),
    )
    return None, web.json_response(
        {"id": body.get("id"), "status": "awaiting-approval"}, status=202
    )
