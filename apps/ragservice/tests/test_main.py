import sys
import os
from unittest.mock import MagicMock, patch

import pytest

# ── Mock RAGPipeline BEFORE importing main ─────────────────────────────────────
# main.py creates a RAGPipeline() at module level which would download a
# 80MB embedding model. We replace it with a mock for fast, offline tests.
_mock_pipeline = MagicMock()
_mock_pipeline.vector_store = MagicMock()    # truthy = "store is ready"
_mock_pipeline.ingest.return_value = 5
_mock_pipeline.query.return_value = {
    "answer": "Use docker compose up -d secureship to restart the container",
    "is_relevant": True,
    "sources": [
        {"content": "ServiceDown runbook: docker ps, docker logs", "metadata": {"type": "runbook"}}
    ],
}

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

with patch("rag_pipeline.RAGPipeline", return_value=_mock_pipeline):
    from fastapi.testclient import TestClient
    from main import app

client = TestClient(app)


# ── Health ────────────────────────────────────────────────────────────────────

def test_health_returns_200():
    resp = client.get("/health")
    assert resp.status_code == 200

def test_health_body():
    resp = client.get("/health")
    body = resp.json()
    assert body["status"] == "healthy"
    assert body["service"] == "ragservice"
    assert "vector_store_ready" in body


# ── Root ──────────────────────────────────────────────────────────────────────

def test_root_lists_endpoints():
    resp = client.get("/")
    assert resp.status_code == 200
    body = resp.json()
    assert "POST /query" in body["endpoints"]
    assert "POST /ingest" in body["endpoints"]


# ── Metrics ───────────────────────────────────────────────────────────────────

def test_metrics_returns_prometheus_format():
    resp = client.get("/metrics")
    assert resp.status_code == 200
    # Prometheus text format always starts with "# HELP" or a metric name
    assert "llm_requests_total" in resp.text or "rag_queries_total" in resp.text


# ── Ingest ────────────────────────────────────────────────────────────────────

def test_ingest_success():
    resp = client.post("/ingest", json={"texts": ["doc one", "doc two"]})
    assert resp.status_code == 200
    assert resp.json()["chunks_created"] == 5    # mock returns 5

def test_ingest_with_metadata():
    resp = client.post("/ingest", json={
        "texts": ["ServiceDown runbook content"],
        "metadatas": [{"type": "runbook", "alert": "ServiceDown"}]
    })
    assert resp.status_code == 200

def test_ingest_missing_texts_returns_422():
    resp = client.post("/ingest", json={})    # missing required field
    assert resp.status_code == 422


# ── Query ─────────────────────────────────────────────────────────────────────

def test_query_success():
    resp = client.post("/query", json={"question": "What do I do when a service is down?"})
    assert resp.status_code == 200

def test_query_response_shape():
    resp = client.post("/query", json={"question": "How do I handle high CPU?"})
    body = resp.json()
    assert "answer" in body
    assert "is_relevant" in body
    assert "sources" in body
    assert isinstance(body["sources"], list)

def test_query_answer_is_string():
    resp = client.post("/query", json={"question": "Describe the infrastructure"})
    body = resp.json()
    assert isinstance(body["answer"], str)
    assert len(body["answer"]) > 0

def test_query_missing_question_returns_422():
    resp = client.post("/query", json={})
    assert resp.status_code == 422
