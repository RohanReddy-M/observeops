# Runbook: RAGHighUngroundedRate

**Alert:** RAGHighUngroundedRate | **Severity:** Warning
**Meaning:** Over 50% of RAG answers not grounded in retrieved context.

This is a model quality alert, not an infrastructure alert.

## Fix
```bash
curl -X POST http://localhost:8003/ingest -H 'Content-Type: application/json' -d '{"texts": ["your runbook content here"]}' 
```bash

Ingest more relevant runbooks to improve retrieval quality.
