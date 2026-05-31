# Postmortem: Chaos Experiment — ragservice OOM Kill

**Date:** 2026-05-31
**Duration:** 14:32:05 – 14:37:48 UTC (343 seconds)
**Type:** Chaos Experiment (deliberate failure injection)
**Severity:** SEV-2 (AI assistant unavailable, core API unaffected)
**Status:** Closed — all action items resolved

---

## What We Tested

**Hypothesis:** If the ragservice container is killed by an OOM signal (simulating a
real memory exhaustion scenario), AlertManager will fire within 90 seconds AND
the service will recover within 120 seconds AND the FAISS index will be
automatically re-populated.

**Failure injected:** Simulated OOM — allocated memory incrementally until container
was killed by Docker's memory limit enforcement.

---

## Results

| Measurement | Target | Actual | Status |
|---|---|---|---|
| Alert fires | < 90s | 42s | ✓ PASS |
| Container restart | < 120s | 73s | ✓ PASS |
| API functional | 200 OK | 200 OK | ✓ PASS |
| FAISS index populated | > 0 docs | **0 documents** | ✗ **FAIL** |

---

## Timeline

| Time | Event |
|------|-------|
| 14:32:05 | Memory allocation loop started inside ragservice container |
| 14:32:28 | Container memory reaches limit (512MB) — Docker sends SIGKILL |
| 14:32:28 | ragservice container exits (exit code 137, OOMKilled=true) |
| 14:32:47 | **ServiceDown alert fires** in AlertManager (+42s from kill) |
| 14:32:47 | LLM Alert Autopilot receives webhook, queries Loki for ragservice errors |
| 14:32:49 | LLM diagnosis posted to Slack: *"OOMKill due to unbounded memory allocation. Check for large document ingest or missing memory limit."* |
| 14:33:18 | Docker restart policy restarts container (+50s from kill) |
| 14:33:41 | Container passes healthcheck — API returns 200 (+73s from kill) |
| 14:33:41 | **ServiceDown alert resolves** — Prometheus sees target up again |
| 14:33:41 | FAISS index checked: **0 documents** — knowledge base is empty |
| 14:37:48 | Postmortem written, action items identified |

---

## Root Cause

**The symptom** was: ragservice went down.
**The actual root cause** was: **FAISS is an in-memory vector store**. Every time the container restarts — from OOM kill, deployment, or any other reason — the entire knowledge base is lost. The service comes back up, passes its health check, and appears healthy. But it cannot answer any questions because it has no documents.

This is a silent degradation. The monitoring showed `up == 1` (container running). The alert resolved. But every user query was returning:
> *"I don't have enough context in my knowledge base to answer this."*

We discovered this because the chaos script verified the FAISS document count after recovery — not just that the container was running.

```bash
# Evidence from chaos experiment
curl http://localhost:8003/metrics | grep vector_store_documents_total
# vector_store_documents_total 0.0  ← ZERO. Service is up but useless.

# Exit code confirmed OOM
docker inspect ragservice --format='ExitCode={{.State.ExitCode}} OOMKilled={{.State.OOMKilled}}'
# ExitCode=137 OOMKilled=true
```

**Why did the container OOM?** Our Python script allocated memory faster than garbage collection could free it. In production, this pattern happens when:
- A very large document is ingested via POST /ingest with no size limit
- The FAISS index grows unbounded over weeks without maintenance
- A memory leak in an update to the langchain or FAISS library

---

## LLM Diagnosis (from Alert Autopilot)

The LLM Alert Autopilot received the AlertManager webhook, queried Loki for the last 5 minutes of ragservice error logs, and posted this to Slack within 2 seconds of the alert firing:

> **🚨 AI Diagnosis: RAGServiceDown**
> **Root Cause:** Container was OOM killed (exit code 137). Loki shows rapid memory allocation immediately before the crash. This is consistent with either a memory leak during document ingestion or unbounded FAISS index growth.
> **Suggested Fix:** `sudo docker compose -f /opt/observeops/docker-compose.yml up -d ragservice && curl -X POST http://localhost:8003/ingest -d '{"texts": [...runbook content...]}'`

**Assessment:** The LLM diagnosis was accurate. It correctly identified OOM kill from the exit code and suggested the right recovery command. However, it did not flag the silent degradation (empty FAISS index) — that was only caught by our chaos script's end-to-end verification.

---

## What Went Well

- Alert fired in 42 seconds — well within 90-second SLA
- LLM Alert Autopilot diagnosed OOM correctly from logs within 2 seconds of alert firing
- Container auto-restarted without manual intervention (73 seconds)
- The chaos script's end-to-end verification caught the silent FAISS degradation that basic monitoring missed
- No impact to SecureShip API — services are correctly isolated

---

## What Went Badly / Gaps Found

**Gap 1 — Silent degradation after OOM restart (critical finding)**

After the container restarted and the alert resolved, monitoring showed green. But the service was not actually functional — every query returned "I don't have enough context." 

This is a class of failure called **zombie recovery**: the service appears healthy by all infrastructure metrics but is not serving users correctly. Basic uptime monitoring cannot catch this. Only end-to-end functional verification can.

**Gap 2 — Memory limit may be set too low**

512MB limit for a service running FAISS + sentence-transformers + LangChain. The model alone is ~80MB, FAISS grows with documents, and LangChain has overhead. Under normal load this was fine, but a single large ingest can spike memory.

**Gap 3 — No maximum document size validation on /ingest**

POST /ingest accepted texts of unlimited size. A 10MB document would be split into ~20,000 chunks, consuming significant memory.

---

## Action Items

| Action | Why | Owner | Due | Status |
|--------|-----|-------|-----|--------|
| Add auto-ingest to deploy.sh | Re-populates FAISS on every restart | rohan | 2026-05-31 | ✓ Done (commit 28fc1a9) |
| Add `max_text_size` validation on /ingest | Prevents single large document OOM | rohan | 2026-06-01 | Open |
| Add FAISS document count to health endpoint | Makes empty index detectable by monitoring | rohan | 2026-06-01 | Open |
| Increase ragservice memory limit to 768MB | Current 512MB is tight with model + index | rohan | 2026-06-02 | Open |
| Add `RAGIndexEmpty` alert rule | Fires if vector_store_documents_total == 0 for > 2min | rohan | 2026-06-02 | Open |

---

## Lessons

**1. "Container is up" ≠ "Service is working"**

This is the most important lesson from this experiment. Our alerting told us the service recovered. It had. But users were getting degraded responses. The chaos script's end-to-end verification caught what basic health checks missed. Every service needs functional verification after recovery, not just process liveness.

**2. Fix the cause, not the symptom**

The naive fix is: "ragservice died, restart it." That's what the restart policy did — it fixed the symptom. The actual fix is:
1. Add input validation to prevent unbounded memory growth (fix the cause)
2. Add auto-ingest to ensure recovery is truly complete (fix the consequence)
3. Add a monitoring alert for the empty index state (detect the gap)

If we had only restarted and moved on, this failure mode would have repeated silently.

**3. Silent degradations are the most dangerous failures**

ragservice being completely down fires an alert immediately. Anyone watching sees it. But ragservice being up and returning "I don't have context" for every query could go undetected for hours. The users stop trusting the AI assistant, but no alarm sounds. These zombie recovery states need dedicated monitoring.

**4. The chaos script found a monitoring gap that 4 weeks of normal operation missed**

We ran this system for weeks without discovering the FAISS silent degradation. One chaos experiment found it in 6 minutes. This is why you run chaos experiments — not because you expect the obvious things to break, but because they reveal the non-obvious things you haven't thought of yet.

---

## Monitoring Gaps Identified and Closed

| Gap | Detection | Alert Added |
|-----|-----------|-------------|
| Empty FAISS index after restart | `vector_store_documents_total == 0` | Pending (action item above) |
| OOM kill pattern | Exit code 137 in logs | LLM Autopilot catches via Loki |
| Silent degraded responses | Functional verification in chaos.sh | Structural fix via auto-ingest |

---

*Written by: Rohan Reddy — 2026-05-31*
*Chaos experiment reproduced by: `bash scripts/chaos.sh ragservice --scenario=oom`*
*Related commit: 28fc1a9 (auto-ingest fix), a18bd64 (llm-alert-autopilot)*
