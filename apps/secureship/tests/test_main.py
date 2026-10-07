"""
Tests for SecureShip API.
Run: pytest apps/secureship/tests/ -v
"""
import pytest
from fastapi.testclient import TestClient
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
from main import app

client = TestClient(app, follow_redirects=False)
client_follow = TestClient(app, follow_redirects=True)


# ── Health / meta ─────────────────────────────────────────────────────────────
def test_health_check():
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "healthy"


def test_root_html():
    response = client.get("/")
    assert response.status_code == 200
    assert "text/html" in response.headers["content-type"]


def test_metrics_endpoint():
    response = client.get("/metrics")
    assert response.status_code == 200
    assert b"http_requests_total" in response.content


# ── v1 API ────────────────────────────────────────────────────────────────────
def test_list_ships_v1():
    response = client_follow.get("/api/v1/ships")
    assert response.status_code == 200
    data = response.json()
    assert "ships" in data
    assert len(data["ships"]) > 0
    assert "total" in data


def test_get_ship_found_v1():
    response = client_follow.get("/api/v1/ships/ship-001")
    assert response.status_code == 200
    assert response.json()["ship_id"] == "ship-001"


def test_get_ship_not_found_v1():
    response = client_follow.get("/api/v1/ships/does-not-exist")
    assert response.status_code == 404


def test_create_ship_valid():
    payload = {"ship_id": "ship-test", "name": "SS Test", "status": "active", "cargo": "grain"}
    response = client_follow.post("/api/v1/ships", json=payload)
    assert response.status_code == 200
    assert response.json()["ship"]["ship_id"] == "ship-test"


def test_create_ship_missing_field():
    # Missing 'cargo'
    payload = {"ship_id": "ship-bad", "name": "SS Bad", "status": "active"}
    response = client_follow.post("/api/v1/ships", json=payload)
    assert response.status_code == 422


def test_create_ship_invalid_status():
    # status must be one of: active | docked | transit
    payload = {"ship_id": "ship-bad2", "name": "SS Bad", "status": "unknown", "cargo": "iron"}
    response = client_follow.post("/api/v1/ships", json=payload)
    assert response.status_code == 422


def test_create_ship_invalid_ship_id():
    # ship_id must be alphanumeric + hyphens only
    payload = {"ship_id": "ship bad!", "name": "SS Bad", "status": "active", "cargo": "coal"}
    response = client_follow.post("/api/v1/ships", json=payload)
    assert response.status_code == 422


# ── Backward-compat redirects ─────────────────────────────────────────────────
def test_redirect_list_ships():
    response = client.get("/api/ships")
    assert response.status_code == 301
    assert response.headers["location"].endswith("/api/v1/ships")


def test_redirect_get_ship():
    response = client.get("/api/ships/ship-001")
    assert response.status_code == 301
    assert "/api/v1/ships/ship-001" in response.headers["location"]


def test_redirect_post_ship():
    # 308 preserves the POST method and body
    payload = {"ship_id": "ship-redir", "name": "SS Redir", "status": "docked", "cargo": "oil"}
    response = client.post("/api/ships", json=payload)
    assert response.status_code == 308
    assert response.headers["location"].endswith("/api/v1/ships")


# ── Correlation ID ────────────────────────────────────────────────────────────
def test_correlation_id_propagated():
    response = client_follow.get("/health", headers={"X-Request-ID": "test-corr-123"})
    assert response.headers.get("x-request-id") == "test-corr-123"


def test_correlation_id_generated():
    response = client_follow.get("/health")
    assert "x-request-id" in response.headers
    assert len(response.headers["x-request-id"]) == 36  # UUID4 length


# ── PUT (update ship) ─────────────────────────────────────────────────────────
def test_update_ship_partial():
    # Partial update — only 'status' changed, other fields preserved
    response = client_follow.put("/api/v1/ships/ship-001", json={"status": "docked"})
    assert response.status_code == 200
    body = response.json()
    assert body["ship"]["status"] == "docked"
    assert body["ship"]["ship_id"] == "ship-001"  # unchanged
    assert "name" in body["ship"]                  # other fields preserved


def test_update_ship_all_fields():
    response = client_follow.put(
        "/api/v1/ships/ship-001",
        json={"name": "SS Updated", "status": "transit", "cargo": "steel"},
    )
    assert response.status_code == 200
    body = response.json()
    assert body["ship"]["name"] == "SS Updated"
    assert body["ship"]["cargo"] == "steel"


def test_update_ship_invalid_status():
    response = client_follow.put("/api/v1/ships/ship-001", json={"status": "flying"})
    assert response.status_code == 422


def test_update_ship_not_found():
    response = client_follow.put("/api/v1/ships/no-such-ship", json={"status": "docked"})
    assert response.status_code == 404


# ── DELETE ────────────────────────────────────────────────────────────────────
def test_delete_ship():
    # Create a ship, then delete it
    client_follow.post(
        "/api/v1/ships",
        json={"ship_id": "ship-to-delete", "name": "SS Doomed", "status": "docked", "cargo": "sand"},
    )
    response = client_follow.delete("/api/v1/ships/ship-to-delete")
    assert response.status_code == 200
    # Confirm it's gone
    get_response = client_follow.get("/api/v1/ships/ship-to-delete")
    assert get_response.status_code == 404


def test_delete_ship_not_found():
    response = client_follow.delete("/api/v1/ships/ghost-ship")
    assert response.status_code == 404


# ── API key auth (disabled when API_KEY env is not set) ───────────────────────
def test_auth_open_when_key_not_configured(monkeypatch):
    monkeypatch.setenv("API_KEY", "")
    # Re-import to pick up env change isn't needed — API_KEY read at startup;
    # when unset the verify_api_key dependency is a no-op, so requests pass
    response = client_follow.get("/api/v1/ships")
    assert response.status_code == 200


# ── Regression tests for the October 2026 self-review ─────────────────────────
# Each test below fails against the code as it was before that review. They exist
# so the specific bug cannot come back silently, which is the only reason a
# regression test is worth writing.

def test_metrics_label_uses_route_template_not_raw_path():
    """Cardinality guard: a per-item path must not become its own time series."""
    client_follow.get("/api/v1/ships/ship-001")
    client_follow.get("/api/v1/ships/ship-002")
    body = client.get("/metrics").content.decode()
    # The template is the label value...
    assert "/api/v1/ships/{ship_id}" in body
    # ...and the concrete ids never appear as labels.
    assert 'endpoint="/api/v1/ships/ship-001"' not in body
    assert 'endpoint="/api/v1/ships/ship-002"' not in body


def test_structured_log_fields_are_emitted(caplog):
    """The JSON formatter must emit `extra=` fields, not drop them."""
    import json as _json
    import logging as _logging
    from main import JSONFormatter

    record = _logging.LogRecord(
        name="secureship", level=_logging.INFO, pathname="", lineno=0,
        msg="request", args=None, exc_info=None,
    )
    record.request_id = "abc-123"
    record.duration_ms = 12.5
    emitted = _json.loads(JSONFormatter().format(record))

    assert emitted["message"] == "request"
    assert emitted["request_id"] == "abc-123"      # was silently dropped before
    assert emitted["duration_ms"] == 12.5
    assert "args" not in emitted                    # reserved attrs stay out


def test_readiness_endpoint_reports_dependency_state():
    """/ready is readiness and says whether a dependency was actually checked."""
    response = client.get("/ready")
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ready"
    # No DynamoDB configured in tests, so there is nothing to check and we say so
    # rather than claiming a backend we never contacted.
    assert body["storage"] == "local"
    assert body["dependency_checked"] is False


def test_status_filter_is_applied():
    response = client_follow.get("/api/v1/ships?status=docked")
    assert response.status_code == 200
    ships = response.json()["ships"]
    assert len(ships) > 0
    assert all(s["status"] == "docked" for s in ships)


def test_status_filter_rejects_unknown_value():
    response = client_follow.get("/api/v1/ships?status=sunk")
    assert response.status_code == 400


# ── Rate-limit identity ───────────────────────────────────────────────────────
# Which caller a request is counted against. Getting this wrong either puts every
# client in one bucket (the proxy's address) or lets a client pick its own bucket.

class _FakeRequest:
    def __init__(self, headers, client_host="172.18.0.5"):
        self.headers = headers
        self.client = type("Client", (), {"host": client_host})()


def test_rate_limit_key_is_the_real_api_key_and_never_the_key_itself(monkeypatch):
    import main
    monkeypatch.setattr(main, "API_KEY", "the-real-key")
    request = _FakeRequest({"X-API-Key": "the-real-key", "X-Real-IP": "203.0.113.9"})
    bucket = main._rate_limit_key(request)
    assert bucket.startswith("key:")
    assert "the-real-key" not in bucket          # a hash, so the secret is not stored


def test_rate_limit_key_ignores_a_made_up_api_key(monkeypatch):
    """A caller must not be able to mint itself a new bucket per request."""
    import main
    monkeypatch.setattr(main, "API_KEY", "the-real-key")
    first = main._rate_limit_key(_FakeRequest({"X-API-Key": "guess-1", "X-Real-IP": "203.0.113.9"}))
    second = main._rate_limit_key(_FakeRequest({"X-API-Key": "guess-2", "X-Real-IP": "203.0.113.9"}))
    assert first == second == "203.0.113.9"      # counted against the address instead


def test_rate_limit_key_uses_the_address_our_proxy_vouches_for():
    from main import _rate_limit_key
    # X-Real-IP is set by our nginx. The leftmost X-Forwarded-For entry is whatever
    # the client chose to send and must never be the identity.
    request = _FakeRequest({"X-Real-IP": "203.0.113.9",
                            "X-Forwarded-For": "6.6.6.6, 203.0.113.9, 10.0.1.20"})
    assert _rate_limit_key(request) == "203.0.113.9"


def test_rate_limit_key_ignores_a_forged_leftmost_forwarded_for():
    from main import _rate_limit_key
    request = _FakeRequest({"X-Forwarded-For": "6.6.6.6, 203.0.113.9"})
    assert _rate_limit_key(request) == "203.0.113.9"      # the hop that reached our proxy
    assert _rate_limit_key(request) != "6.6.6.6"


def test_rate_limit_key_falls_back_to_the_socket_address():
    from main import _rate_limit_key
    assert _rate_limit_key(_FakeRequest({}, client_host="192.0.2.44")) == "192.0.2.44"


# ── Auth enforced ─────────────────────────────────────────────────────────────
# The suite above only ever ran with auth switched off, which is how the API was
# deployed with no key at all without a single test noticing.

def test_auth_rejects_a_missing_or_wrong_key_and_accepts_the_right_one(monkeypatch):
    import main
    monkeypatch.setattr(main, "API_KEY", "the-real-key")
    assert client.get("/api/v1/ships").status_code == 401
    assert client.get("/api/v1/ships", headers={"X-API-Key": "wrong"}).status_code == 401
    assert client.get("/api/v1/ships", headers={"X-API-Key": "the-real-key"}).status_code == 200


def test_health_stays_open_when_auth_is_on(monkeypatch):
    """Load balancers and Prometheus cannot send a key; liveness must not need one."""
    import main
    monkeypatch.setattr(main, "API_KEY", "the-real-key")
    assert client.get("/health").status_code == 200
    assert client.get("/metrics").status_code == 200


# ── Datastore failure contract ────────────────────────────────────────────────
class _BrokenTable:
    """Stands in for DynamoDB when credentials or the network are gone."""
    def _fail(self, *args, **kwargs):
        raise RuntimeError("Unable to locate credentials for arn:aws:iam::123456789012:role/secret-role")
    scan = get_item = put_item = delete_item = load = _fail


def test_every_datastore_failure_is_a_503_not_a_500(monkeypatch):
    import main
    monkeypatch.setattr(main, "get_dynamodb_table", lambda: _BrokenTable())
    payload = {"ship_id": "ship-x", "name": "SS X", "status": "active", "cargo": "grain"}
    assert client.get("/api/v1/ships").status_code == 503
    assert client.get("/api/v1/ships/ship-001").status_code == 503
    assert client.post("/api/v1/ships", json=payload).status_code == 503      # was a 500


def test_readiness_failure_does_not_leak_the_reason(monkeypatch):
    import main
    monkeypatch.setattr(main, "get_dynamodb_table", lambda: _BrokenTable())
    monkeypatch.setitem(main._READY_CACHE, "checked_at", 0.0)
    response = client.get("/ready")
    assert response.status_code == 503
    assert response.json()["status"] == "not_ready"
    assert "arn:aws" not in response.text         # account and role stay in the logs
    assert "error" not in response.json()
    monkeypatch.setitem(main._READY_CACHE, "checked_at", 0.0)   # do not poison later tests


def test_datastore_handlers_do_not_block_the_event_loop():
    """They call a blocking client, so they must be plain functions (threadpool)."""
    import inspect
    import main
    for handler in (main.list_ships, main.get_ship, main.create_ship,
                    main.update_ship, main.delete_ship, main.readiness_check):
        assert not inspect.iscoroutinefunction(handler), handler.__name__


def test_dynamodb_client_has_deadlines(monkeypatch):
    """botocore's default is 60 s per attempt; a request must not wait that long."""
    import main
    if not main.DYNAMODB_AVAILABLE:
        pytest.skip("boto3 not installed")
    monkeypatch.setattr(main, "DYNAMODB_TABLE", "any-table")
    monkeypatch.setattr(main, "_TABLE", None)
    main.get_dynamodb_table()
    assert main._BOTO_CONFIG.connect_timeout <= 3
    assert main._BOTO_CONFIG.read_timeout <= 5
    assert main._BOTO_CONFIG.retries["max_attempts"] <= 3
    monkeypatch.setattr(main, "_TABLE", None)
