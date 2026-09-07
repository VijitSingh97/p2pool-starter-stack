"""One-time Telegram gates shared by control verbs and configuration approval."""

import time
import uuid


class ControlGate:
    """Per-operator, deny-on-timeout confirmation for fixed Telegram control verbs."""

    def __init__(self, timeout_s, max_prompts_per_hour=10):
        self._timeout = timeout_s
        self._max = max_prompts_per_hour
        self._pending = {}
        self._prompts = {}

    def open(self, verb, user_id, now):
        self._sweep(now)
        owner = str(user_id)
        recent = [seen for seen in self._prompts.get(owner, []) if seen > now - 3600]
        if len(recent) >= self._max:
            self._prompts[owner] = recent
            return None
        token = uuid.uuid4().hex
        self._pending[token] = (verb, owner, now + self._timeout)
        recent.append(now)
        self._prompts[owner] = recent
        return token

    def confirm(self, token, user_id, now):
        self._sweep(now)
        rec = self._pending.pop(token, None)
        if rec is None:
            return None
        verb, owner, deadline = rec
        return verb if str(user_id) == owner and now < deadline else None

    def _sweep(self, now):
        self._pending = {token: rec for token, rec in self._pending.items() if rec[2] > now}


class ConfigApprovalGate:
    """Bind one Telegram approval to a host preview, dashboard actor, and payout suffixes."""

    def __init__(self, timeout_s):
        self._timeout = float(timeout_s)
        self._pending = {}
        self._by_preview = {}
        self._approved = {}

    def request(self, preview_id, actor, payout_suffixes):
        """Return ``(accepted, token)``; a null token means an identical prompt is pending."""
        now = time.monotonic()
        existing = self._by_preview.get(preview_id)
        if existing:
            rec = self._pending.get(existing)
            if rec and rec["deadline"] > now:
                return (rec["actor"] == actor and rec["payout_suffixes"] == payout_suffixes, None)
            self._pending.pop(existing, None)
            self._by_preview.pop(preview_id, None)
        token = uuid.uuid4().hex
        self._pending[token] = {
            "preview_id": preview_id,
            "actor": actor,
            "payout_suffixes": dict(payout_suffixes),
            "deadline": now + self._timeout,
        }
        self._by_preview[preview_id] = token
        return True, token

    def confirm(self, token, user_id, allowed_ids):
        rec = self._pending.pop(token, None)
        if rec:
            self._by_preview.pop(rec["preview_id"], None)
        if rec is None or str(user_id) not in allowed_ids or time.monotonic() >= rec["deadline"]:
            return None
        rec["approver"] = f"tg-{user_id}"
        self._approved[rec["preview_id"]] = rec
        return rec

    def take(self, preview_id, actor, payout_suffixes):
        rec = self._approved.pop(preview_id, None)
        if (
            not rec
            or time.monotonic() >= rec["deadline"]
            or rec["actor"] != actor
            or rec["payout_suffixes"] != payout_suffixes
        ):
            return None
        return {
            "preview_id": preview_id,
            "actor": actor,
            "payout_suffixes": dict(payout_suffixes),
            "approver": rec["approver"],
        }


def config_prompt_payload(chat_id, prefix, token, actor, preview_values):
    """Build a concrete host-produced, non-secret Telegram confirmation prompt."""
    lines = [f"{prefix}Approve configuration change for dashboard user {actor}?"]
    for item in preview_values:
        lines.append(f"{item.get('key', '')}: {item.get('old', '')} → {item.get('new', '')}")
    lines.append("Denied automatically if not confirmed soon.")
    return {
        "chat_id": chat_id,
        "text": "\n".join(lines),
        "disable_web_page_preview": True,
        "reply_markup": {
            "inline_keyboard": [
                [
                    {
                        "text": "✅ Approve configuration change",
                        "callback_data": f"approve-config:{token}",
                    }
                ]
            ]
        },
    }
