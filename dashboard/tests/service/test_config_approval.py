from types import SimpleNamespace

from mining_dashboard.service import telegram_commands
from mining_dashboard.service.config_approval import ConfigApprovalGate, config_prompt_payload


def test_concrete_prompt_and_allowlisted_approval_bind_full_preview_and_actor():
    gate = ConfigApprovalGate(timeout_s=60)
    preview_id = "11111111-1111-4111-8111-111111111111"
    suffixes = {"monero": "12345678"}
    accepted, token = gate.request(preview_id, "admin", suffixes)
    assert accepted and token
    payload = config_prompt_payload(
        "42",
        "[Pithead] ",
        token,
        "admin",
        [{"key": "monero.wallet_address", "old": "full-old", "new": "full-new-12345678"}],
    )
    assert "full-old" in payload["text"]
    assert "full-new-12345678" in payload["text"]
    assert payload["text"].endswith("Denied automatically if not confirmed soon.")
    assert gate.take(preview_id, "admin", suffixes) is None
    assert gate.confirm(token, "7", frozenset({"7"}))["approver"] == "tg-7"
    assert gate.take(preview_id, "admin", suffixes) == {
        "preview_id": preview_id,
        "actor": "admin",
        "approver": "tg-7",
        "payout_suffixes": suffixes,
    }
    assert gate.take(preview_id, "admin", suffixes) is None


def test_foreign_identity_cannot_approve():
    gate = ConfigApprovalGate(timeout_s=60)
    accepted, token = gate.request("preview", "admin", {})
    assert accepted
    assert gate.confirm(token, "999", frozenset({"7"})) is None
    assert gate.take("preview", "admin", {}) is None


def test_pending_prompt_is_deduplicated_but_cannot_be_rebound():
    gate = ConfigApprovalGate(timeout_s=60)
    assert gate.request("preview", "admin", {})[0]
    assert gate.request("preview", "admin", {}) == (True, None)
    assert gate.request("preview", "forged", {}) == (False, None)


def test_config_approval_poll_includes_callbacks_without_control_verbs(monkeypatch):
    data = SimpleNamespace(latest_data={}, state_manager=object())
    bot = telegram_commands.TelegramCommandBot(
        data,
        enabled=True,
        bot_token="token",
        chat_id="42",
        control_enabled=False,
        allowed_ids=("7",),
    )
    seen = {}

    class Response:
        def raise_for_status(self):
            return None

        def json(self):
            return {"ok": True, "result": []}

    monkeypatch.setattr(
        telegram_commands,
        "bounded_get",
        lambda _url, **kwargs: seen.update(kwargs) or Response(),
    )
    bot._get_updates(0)
    assert "callback_query" in seen["params"]["allowed_updates"]
