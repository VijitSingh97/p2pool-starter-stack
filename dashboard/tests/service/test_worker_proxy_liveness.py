from mining_dashboard.service.data_helpers import _parse_proxy_list_worker


def test_recent_accepted_share_keeps_worker_online_when_connection_count_lags():
    row = ["rig", "10.0.0.1", 0, 5, 0, 0, 0, 970_000, 1.0, 2.0, 0, 0, 0]
    assert _parse_proxy_list_worker(row, now=1000)["status"] == "online"
    assert _parse_proxy_list_worker(row, now=1301)["status"] == "offline"
