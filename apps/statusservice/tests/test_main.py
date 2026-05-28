"""
Tests for StatusService.
Run: pytest apps/statusservice/tests/ -v
"""
import pytest
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
from main import app as flask_app

flask_app.config["TESTING"] = True


@pytest.fixture
def client():
    with flask_app.test_client() as c:
        yield c


# ── Health / meta ─────────────────────────────────────────────────────────────
def test_health(client):
    r = client.get("/health")
    assert r.status_code == 200
    data = r.get_json()
    assert data["status"] == "healthy"
    assert data["service"] == "statusservice"


def test_root(client):
    r = client.get("/")
    assert r.status_code == 200
    data = r.get_json()
    assert "endpoints" in data


def test_metrics(client):
    r = client.get("/metrics")
    assert r.status_code == 200
    assert b"status_requests_total" in r.data


# ── Status endpoint ───────────────────────────────────────────────────────────
def test_status_returns_services(client):
    r = client.get("/status")
    assert r.status_code == 200
    data = r.get_json()
    assert "services" in data
    assert "secureship" in data["services"]
    assert "uptime_seconds" in data


# ── Failure simulator ─────────────────────────────────────────────────────────
def test_fail_no_errors_by_default(client):
    # With FAILURE_RATE=0 (default), every call must succeed
    os.environ.pop("FAILURE_RATE", None)
    for _ in range(10):
        r = client.get("/fail")
        assert r.status_code == 200


def test_fail_always_errors_at_rate_1(client, monkeypatch):
    monkeypatch.setenv("FAILURE_RATE", "1.0")
    r = client.get("/fail")
    assert r.status_code == 500
    assert "error" in r.get_json()


# ── Load endpoint (short duration) ────────────────────────────────────────────
def test_load_endpoint(client):
    r = client.post("/load?duration=1")
    assert r.status_code == 200
    data = r.get_json()
    assert "iterations" in data
    assert data["iterations"] > 0
