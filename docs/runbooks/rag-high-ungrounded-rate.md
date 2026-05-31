# Runbook: RAGHighUngroundedRate

**Alert:** `RAGHighUngroundedRate` | **Severity:** Warning
**Meaning:** Over 50% of RAG answers are not grounded in retrieved context.
**Environment:** RAGService (LangGraph + FAISS)

---

## Step 0 — Understand what this alert means

This is NOT an infrastructure alert. The system is running. This is a **model quality alert** — the AI is making up answers instead of basing them on your runbooks.

The grounding check in RAGService works like this:
1. User asks a question
2. FAISS searches for relevant documents (cosine similarity)
3. If similarity score is too low (d² >= 1.5) → no relevant context found → LangGraph routes to `no_context` node → answer is ungrounded
4. This metric tracks how often that happens

High ungrounded rate means: **the FAISS vector store doesn't have documents relevant to what people are asking.**

---

## Step 1 — Diagnose the state of the vector store

```bash
# How many documents are currently in FAISS?
sudo docker exec ragservice python3 -c "
import sys; sys.path.insert(0, '/app')
from rag_pipeline import pipeline
print(f'Documents in FAISS: {pipeline.vector_store.index.ntotal}')
"
```

| Document count | Meaning |
|---|---------|
| 0 | RAGService was restarted — vector store is empty. This is the most common cause. |
| < 10 | Very few runbooks ingested |
| 10-50 | Normal for this project |

---

## Step 2 — Root cause A: Vector store is empty (most common)

RAGService stores vectors in memory (FAISS). On every restart, the store resets to zero. You must re-ingest all runbooks after restart.

```bash
# Ingest all runbooks from the docs/runbooks directory
for f in /opt/observeops/docs/runbooks/*.md; do
    echo "Ingesting: $f"
    content=$(cat "$f")
    curl -s -X POST http://localhost:8003/ingest \
      -H "Content-Type: application/json" \
      -d "{\"texts\": [$(echo "$content" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')]}" \
      | python3 -m json.tool | grep chunks
done
```

Wait 30 seconds, then check if the alert resolves.

**Why does this keep happening?**
The FAISS index is in-memory only. Every ragservice restart loses all documents. The permanent fix is to persist the FAISS index to disk or use a persistent vector database. Until then, runbooks must be re-ingested after every restart.

---

## Step 3 — Root cause B: People are asking questions the runbooks don't cover

If documents > 0 but ungrounded rate is still high — the runbooks cover specific alerts but users are asking broader questions.

```bash
# Check recent queries in ragservice logs to see what people are asking
sudo docker logs ragservice --tail=100 2>&1 | grep "question="
```

Add more context to the FAISS store:
```bash
# Example: add an architecture overview
curl -X POST http://localhost:8003/ingest \
  -H "Content-Type: application/json" \
  -d '{
    "texts": ["ObserveOps is a production monitoring system with 3 microservices: SecureShip (FastAPI, port 8001), StatusService (Flask, port 8002), RAGService (FastAPI, port 8003). All run as Docker containers on an EC2 app server. Monitoring runs on a separate EC2 obs server: Prometheus (port 9090), Grafana (port 3000), Loki (port 3100), AlertManager (port 9093). Deploy with: sudo docker compose -f /opt/observeops/docker-compose.yml up -d <service>"],
    "metadatas": [{"type": "architecture", "source": "system_overview"}]
  }'
```

---

## Step 4 — Verify improvement

```bash
# Test a query that was previously ungrounded
curl -s -X POST http://localhost:8003/query \
  -H "Content-Type: application/json" \
  -d '{"question": "service is down what do I do?"}' \
  | python3 -m json.tool | grep is_relevant
# Should return "is_relevant": true
```

---

## Long-term fix

This alert will keep firing after every ragservice restart until the FAISS index is persisted to disk. Add this to the backlog:

- Implement FAISS index save/load on startup/shutdown in `rag_pipeline.py`
- OR replace FAISS with a persistent vector database (ChromaDB, Weaviate)
- Add a startup script that auto-ingests all runbooks when ragservice starts

Until then: this is a known operational limitation. Re-ingest after every restart.
