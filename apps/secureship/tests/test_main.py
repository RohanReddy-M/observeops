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


# ── API key auth (disabled when API_KEY env is not set) ───────────────────────
def test_auth_open_when_key_not_configured(monkeypatch):
    monkeypatch.setenv("API_KEY", "")
    # Re-import to pick up env change isn't needed — API_KEY read at startup;
    # when unset the verify_api_key dependency is a no-op, so requests pass
    response = client_follow.get("/api/v1/ships")
    assert response.status_code == 200
