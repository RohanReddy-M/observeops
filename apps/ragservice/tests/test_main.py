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


# ── Knowledge base loading ────────────────────────────────────────────────────
# What the index is built from at start-up. This is the piece that was wrong in
# production: the runbooks were never loaded, and no test looked.

def test_knowledge_base_is_built_from_the_runbook_files(tmp_path):
    from main import load_knowledge_base
    (tmp_path / "service-down.md").write_text("# Service down\nCheck docker ps first.", encoding="utf-8")
    (tmp_path / "high-latency.md").write_text("# High latency\nLook at p99.", encoding="utf-8")
    (tmp_path / "notes.txt").write_text("not a runbook", encoding="utf-8")
    (tmp_path / "empty.md").write_text("   ", encoding="utf-8")

    texts, metadatas, source = load_knowledge_base(str(tmp_path))

    assert source == "runbooks"
    assert [m["source"] for m in metadatas] == ["high-latency.md", "service-down.md"]   # sorted, .md only, no blanks
    assert all(m["type"] == "runbook" for m in metadatas)
    assert "docker ps" in texts[1]


def test_knowledge_base_falls_back_to_the_built_in_set_and_says_so(tmp_path):
    from main import load_knowledge_base, SEED_DOCUMENTS
    texts, metadatas, source = load_knowledge_base(str(tmp_path))      # empty directory
    assert source == "seed"
    assert len(texts) == len(SEED_DOCUMENTS)
    _, _, source_missing = load_knowledge_base(str(tmp_path / "does-not-exist"))
    assert source_missing == "seed"


def test_health_reports_where_the_knowledge_base_came_from():
    body = client.get("/health").json()
    assert "knowledge_base_source" in body
