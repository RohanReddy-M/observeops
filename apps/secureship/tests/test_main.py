"""
Basic tests for SecureShip API.
Run: pytest apps/secureship/tests/ -v
"""
import pytest
from fastapi.testclient import TestClient
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
from main import app

client = TestClient(app)

def test_health_check():
    """Health endpoint must return 200 with status: healthy"""
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "healthy"

def test_root():
    response = client.get("/")
    assert response.status_code == 200

def test_list_ships():
    response = client.get("/api/ships")
    assert response.status_code == 200
    assert "ships" in response.json()
    assert len(response.json()["ships"]) > 0

def test_get_ship_found():
    response = client.get("/api/ships/1")
    assert response.status_code == 200
    assert response.json()["id"] == 1

def test_get_ship_not_found():
    response = client.get("/api/ships/999")
    assert response.status_code == 404

def test_metrics_endpoint():
    """Prometheus metrics endpoint must return 200"""
    response = client.get("/metrics")
    assert response.status_code == 200
