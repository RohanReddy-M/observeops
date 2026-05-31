import logging
import os
import time
from contextlib import asynccontextmanager
from typing import List, Optional

import prometheus_client
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException
from fastapi.responses import PlainTextResponse
from pydantic import BaseModel

# Load .env before importing anything that reads env vars (e.g. ChatGroq)
load_dotenv()

from llmops import (
    llm_request_duration,
    llm_requests_total,
    rag_documents_retrieved,
    rag_queries_total,
    vector_store_documents,
)
from rag_pipeline import RAGPipeline

# ── Structured JSON logging ────────────────────────────────────────────────────
# Same format as secureship so Loki can parse all services identically
logging.basicConfig(
    level=logging.INFO,
    format='{"time": "%(asctime)s", "level": "%(levelname)s", "service": "ragservice", "message": "%(message)s"}',
)
logger = logging.getLogger(__name__)

# ── Default knowledge base ─────────────────────────────────────────────────────
# These runbooks and incident logs are pre-loaded at startup so the service is
# useful immediately without any manual ingestion.
SEED_DOCUMENTS = [
    {
        "text": (
            "ServiceDown Alert Runbook: When a service is down, check container "
            "status with 'docker ps'. If stopped, read logs with 'docker logs <name>'. "
            "Common causes: OOM kill, port conflict, bad env var. "
            "Fix: docker compose up -d <service>"
        ),
        "metadata": {"type": "runbook", "alert": "ServiceDown", "severity": "critical"},
    },
    {
        "text": (
            "HighErrorRate Alert Runbook: Error rate above 5% triggers this alert. "
            "Check Grafana Loki for level=error logs. If a recent deploy caused the spike, "
            "roll back with: bash scripts/deploy.sh --rollback. "
            "If error rate exceeds 25% the CriticalErrorRate alert fires simultaneously."
        ),
        "metadata": {"type": "runbook", "alert": "HighErrorRate", "severity": "warning"},
    },
    {
        "text": (
            "HighLatency Alert Runbook: p99 latency above 2 seconds triggers this alert. "
            "Check CPU and memory in Grafana. High CPU may mean a load spike from the "
            "/load endpoint on StatusService. High memory causes GC pauses. "
            "Consider horizontal scaling or restarting the affected container."
        ),
        "metadata": {"type": "runbook", "alert": "HighLatency", "severity": "warning"},
    },
    {
        "text": (
            "DiskSpaceCritical Alert Runbook: Disk usage critical. "
            "Run 'df -h' to see usage and 'du -sh /*' to find large directories. "
            "Docker images and Loki logs are common culprits. "
            "Free space with: docker system prune -f. "
            "Loki stores logs in /opt/observeops/monitoring/loki/"
        ),
        "metadata": {"type": "runbook", "alert": "DiskSpaceCritical", "severity": "critical"},
    },
    {
        "text": (
            "HighCPU Alert Runbook: CPU above 80% for 5 minutes triggers this alert. "
            "Use 'htop' to identify the process. If it is the StatusService /load endpoint "
            "it is an intentional load test. If unexpected, check for memory leaks causing "
            "excessive garbage collection or a stuck background thread."
        ),
        "metadata": {"type": "runbook", "alert": "HighCPU", "severity": "warning"},
    },
    {
        "text": (
            "Incident 2024-01-15 — SecureShip ServiceDown: Container OOM-killed at 14:32 UTC "
            "due to 50 MB memory limit set during incident simulation. "
            "Auto-restarted in 4 minutes. "
            "Action taken: increased memory limits, added OOM-specific alert rule."
        ),
        "metadata": {"type": "incident_log", "service": "secureship", "date": "2024-01-15"},
    },
    {
        "text": (
            "Incident 2024-02-03 — StatusService HighErrorRate: FAILURE_RATE env var "
            "accidentally set to 0.5 in production, causing 50% of requests to return HTTP 500. "
            "Alert fired at 09:15 UTC. Rollback completed in 8 minutes. "
            "Action taken: added env var validation step in CI pipeline."
        ),
        "metadata": {"type": "incident_log", "service": "statusservice", "date": "2024-02-03"},
    },
    {
        "text": (
            "ObserveOps Infrastructure Overview: Two EC2 t3.small instances on AWS. "
            "App server (private subnet) runs SecureShip on port 8001 and StatusService on "
            "port 8002, both behind an Nginx reverse proxy. "
            "Observability server (private subnet) runs Prometheus on 9090, Grafana on 3000, "
            "Loki on 3100, and AlertManager on 9093. "
            "Public subnet holds the Application Load Balancer. "
            "EC2 instances never receive direct internet traffic."
        ),
        "metadata": {"type": "infrastructure", "category": "overview"},
    },
    {
        "text": (
            "RAGService Architecture: FastAPI service using LangChain + LangGraph for RAG. "
            "Documents are embedded with sentence-transformers all-MiniLM-L6-v2 (free, CPU). "
            "Vectors stored in FAISS (in-memory, no database needed). "
            "LangGraph agent flow: retrieve → grade relevance → generate (or fallback). "
            "LLM: Groq llama-3.1-8b-instant (free tier, ~200 tokens/sec). "
            "All LLM calls are tracked via Prometheus metrics in llmops.py."
        ),
        "metadata": {"type": "infrastructure", "category": "ragservice"},
    },
]

# ── Pipeline (module-level singleton) ─────────────────────────────────────────
pipeline = RAGPipeline()


@asynccontextmanager
async def lifespan(app: FastAPI):
    texts = [d["text"] for d in SEED_DOCUMENTS]
    metadatas = [d["metadata"] for d in SEED_DOCUMENTS]
    count = pipeline.ingest(texts, metadatas)
    vector_store_documents.set(count)
    logger.info(f"RAGService ready — {count} document chunks pre-loaded")
    yield


app = FastAPI(
    title="RAGService",
    description="AI-powered incident response assistant for ObserveOps",
    version="1.0.0",
    lifespan=lifespan,
)


# ── Request / Response models ──────────────────────────────────────────────────

class IngestRequest(BaseModel):
    texts: List[str]
    metadatas: Optional[List[dict]] = None


class QueryRequest(BaseModel):
    question: str


# ── Endpoints ─────────────────────────────────────────────────────────────────

@app.get("/health")
def health():
    doc_count = 0
    if pipeline.vector_store is not None:
        try:
            doc_count = pipeline.vector_store.index.ntotal
        except Exception:
            doc_count = -1

    # A service can be UP but effectively broken if the FAISS index is empty.
    # Discovered during chaos experiment 2026-05-31: container restarted,
    # healthcheck passed, but all queries returned "I don't have enough context."
    # Now we surface the index state so Prometheus can alert on it.
    return {
        "status":              "healthy",
        "service":             "ragservice",
        "vector_store_ready":  pipeline.vector_store is not None,
        "vector_store_docs":   doc_count,
        "knowledge_base_state": "empty — re-ingest runbooks" if doc_count == 0 else "loaded",
    }


@app.get("/metrics")
def metrics():
    # Prometheus scrapes this endpoint every 15 seconds
    return PlainTextResponse(
        prometheus_client.generate_latest(), media_type="text/plain"
    )


@app.post("/ingest")
def ingest(request: IngestRequest):
    """
    Add new documents to the FAISS vector store.

    Use this to load runbooks, post-mortems, architecture docs, or
    any text you want the AI to be able to answer questions about.
    """
    if not request.texts:
        raise HTTPException(status_code=400, detail="texts list cannot be empty")
    if any(not t or not t.strip() for t in request.texts):
        raise HTTPException(status_code=400, detail="texts list contains empty strings")
    if len(request.texts) > 100:
        raise HTTPException(status_code=400, detail="maximum 100 texts per request")
    # Postmortem action item 2026-05-31: a single very large document was causing OOM.
    # A 10MB text gets split into ~20,000 chunks, each embedded = huge memory spike.
    # 50KB per text is enough for the longest runbook (most are < 5KB).
    oversized = [i for i, t in enumerate(request.texts) if len(t) > 51200]
    if oversized:
        raise HTTPException(
            status_code=400,
            detail=f"texts at indices {oversized} exceed 50KB limit. Split large documents before ingesting."
        )

    try:
        count = pipeline.ingest(request.texts, request.metadatas)
        vector_store_documents.inc(count)
        logger.info(f"Ingested {count} new chunks — {request.texts[0][:60]}...")
        return {"chunks_created": count, "message": "Ingestion successful"}
    except Exception as exc:
        logger.error(f"Ingest error: {exc}")
        raise HTTPException(status_code=500, detail=str(exc))


@app.post("/query")
def query(request: QueryRequest):
    """
    Ask a question about your infrastructure, incidents, or runbooks.

    The pipeline: embed question → FAISS similarity search → grade relevance
    → generate answer with Groq LLM → return answer + sources.
    """
    if not request.question or not request.question.strip():
        raise HTTPException(status_code=400, detail="question cannot be empty")
    if len(request.question) > 1000:
        raise HTTPException(status_code=400, detail="question exceeds 1000 character limit")

    model = "llama-3.1-8b-instant"
    start = time.time()
    try:
        result = pipeline.query(request.question)
        duration = time.time() - start

        # ── Record LLMOps metrics ──────────────────────────────────────────
        llm_request_duration.labels(model=model, operation="rag_query").observe(duration)
        llm_requests_total.labels(model=model, status="success").inc()
        rag_queries_total.labels(grounded=str(result["is_relevant"]).lower()).inc()
        rag_documents_retrieved.observe(len(result["sources"]))

        logger.info(
            f"Query answered in {duration:.2f}s "
            f"grounded={result['is_relevant']} "
            f"question={request.question[:60]}"
        )
        return result

    except Exception as exc:
        duration = time.time() - start
        llm_request_duration.labels(model=model, operation="rag_query").observe(duration)
        llm_requests_total.labels(model=model, status="error").inc()
        logger.error(f"Query failed after {duration:.2f}s: {exc}")
        raise HTTPException(status_code=500, detail=str(exc))


@app.get("/")
def root():
    return {
        "service": "RAGService",
        "description": "Ask questions about your infrastructure incidents and runbooks",
        "example_questions": [
            "What should I do when SecureShip goes down?",
            "What caused the February 2024 incident?",
            "How do I fix a high error rate alert?",
        ],
        "endpoints": {
            "POST /query": "Ask a question",
            "POST /ingest": "Add documents to the knowledge base",
            "GET /health": "Service health",
            "GET /metrics": "Prometheus metrics",
        },
    }
