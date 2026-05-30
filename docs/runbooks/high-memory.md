# Runbook: HighMemoryUsage

**Alert:** HighMemoryUsage | **Severity:** Warning
**Meaning:** Available RAM below 10% of total.

## Steps
```bash
free -m
docker stats --no-stream
```bash

## Fix
Restart the offending container. RAGService FAISS index is in-memory — restart clears it, re-ingest documents after.
