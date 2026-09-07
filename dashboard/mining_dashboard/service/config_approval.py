"""One-time Telegram gates for fixed control verbs."""

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
