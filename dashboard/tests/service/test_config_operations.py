import json

import pytest

from mining_dashboard.service import config_operations, control_service


@pytest.fixture
def config_paths(tmp_path, monkeypatch):
    live = {
        "monero": {"wallet_address": "4live", "view_key": "", "node_password": ""},
        "workers": {"api_token": ""},
        "dashboard": {"auth": {"password": ""}},
    }
    reference = {
        **live,
        "monero": {**live["monero"], "prune": True},
        "p2pool": {"pool": "mini"},
        "telegram": {"events": {"wallet_changed": True}},
        "ssh": {"enabled": False},
    }
    host = tmp_path / "config.json"
    ref = tmp_path / "reference.json"
    host.write_text(json.dumps(live))
    ref.write_text(json.dumps(reference))
    monkeypatch.setattr(control_service.config, "HOST_CONFIG_PATH", str(host))
    monkeypatch.setattr(control_service.config, "HOST_REFERENCE_PATH", str(ref))


def test_editor_metadata_is_not_a_schema_leaf():
    assert list(
        config_operations.leaf_paths(
            {"_last_apply": {"status": "applied", "id": "abc"}, "p2pool": {"pool": "mini"}}
        )
    ) == ["p2pool.pool"]


def test_sensitive_fields_require_approval_while_password_stays_physical_only(config_paths):
    cfg = control_service.read_config()
    for path in (
        "monero.wallet_address",
        "monero.view_key",
        "monero.node_password",
        "workers.api_token",
    ):
        assert path in cfg["_approval_keys"], path
        assert path not in cfg["_editable_keys"], path
    assert "dashboard.auth.password" not in cfg["_approval_keys"]
    assert "dashboard.auth.password" not in cfg["_editable_keys"]


def test_every_reference_leaf_is_intentionally_classified(config_paths):
    cfg = control_service.read_config()
    classes = {
        **{p: "free" for p in cfg["_editable_keys"]},
        **{p: "confirm" for p in cfg["_confirm_keys"]},
        **{p: "approval" for p in cfg["_approval_keys"]},
    }
    assert classes["p2pool.pool"] == "free"
    assert classes["monero.prune"] == "confirm"
    assert classes["monero.wallet_address"] == "approval"
    assert "dashboard.auth.password" not in classes
    assert "telegram.events.wallet_changed" not in classes
    assert not any(p.startswith("ssh.") for p in classes)
