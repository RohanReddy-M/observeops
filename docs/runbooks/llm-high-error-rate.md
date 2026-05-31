# Runbook: LLMHighErrorRate / LLMHighLatency

**Alert:** `LLMHighErrorRate` (>10% LLM failures) / `LLMHighLatency` (p95 > 15s)
**Severity:** Warning
**Environment:** RAGService + Groq API

---

## Step 0 — Understand the blast radius

This alert means the LLM is failing, NOT that the application is down. SecureShip, StatusService, and the core APIs still work. Only the AI assistant (`/ai/query`) is degraded.

Before acting — is this affecting users or just the AI feature?

```bash
# Is secureship still healthy?
curl -s http://localhost:8001/health

# Is the AI endpoint specifically failing?
curl -s -X POST http://localhost:8003/query \
  -H "Content-Type: application/json" \
  -d '{"question": "test"}' | python3 -m json.tool
```

---

## Step 1 — Is this Groq or our code?

```bash
# Check ragservice logs for the actual error
sudo docker logs ragservice --tail=50 2>&1 | grep -i "groq\|error\|exception\|llm"

# Test Groq directly with the actual key
sudo docker exec ragservice env | grep GROQ_API_KEY
# Then test:
curl -s -X POST https://api.groq.com/openai/v1/chat/completions \
  -H "Authorization: Bearer <key_from_above>" \
  -H "Content-Type: application/json" \
  -d '{"model":"llama-3.1-8b-instant","messages":[{"role":"user","content":"hi"}]}' \
  | python3 -m json.tool | head -10
```

| Groq response | Meaning |
|---|---------|
| `200 OK` with content | Groq is fine — bug is in our code |
| `401 Unauthorized` | API key expired or invalid |
| `429 Too Many Requests` | Rate limit hit — free tier has limits |
| `Connection refused` / timeout | Groq API is down |
| `500` from Groq | Groq internal error |

---

## Step 2 — Diagnose by root cause

### Root Cause A — API key expired or invalid (401)

```bash
# Generate a new key at console.groq.com → API Keys → Create

# Update on the EC2
sudo sed -i "s|GROQ_API_KEY=.*|GROQ_API_KEY=<new_key>|" /opt/observeops/.env

# Restart ragservice to pick up new key
sudo docker compose -f /opt/observeops/docker-compose.yml up -d ragservice
```

### Root Cause B — Rate limit hit (429)

Groq free tier has token-per-minute limits. High query volume hits this.

Evidence: `429` in ragservice logs, errors happen in bursts.

Immediate: wait for rate limit window to reset (usually 1 minute).
Permanent: implement request queuing in RAGService, or upgrade Groq plan.

The system already has a fallback — when LLM fails, it returns raw logs. Users get something, not nothing.

### Root Cause C — Groq API outage

Check status.groq.com. Nothing to do except wait. This is an external dependency.

The LLM Alert Autopilot has a fallback that sends raw logs to Slack when Groq is unavailable. Core alerting still works.

### Root Cause D — Our code is sending malformed requests

Evidence: `400 Bad Request` from Groq in logs.

```bash
sudo docker logs ragservice --tail=20 2>&1 | grep -A5 "400\|BadRequest\|Invalid"
```

This means a recent code change broke the Groq API call format. Roll back the last deploy.

---

## Step 3 — Verify recovery

```bash
curl -s -X POST http://localhost:8003/query \
  -H "Content-Type: application/json" \
  -d '{"question": "what do I do if a service is down?"}'
# Should return {"answer": "...", "is_relevant": true, "sources": [...]}
```

---

## This alert does NOT require waking someone up at 3am

The LLM failing degrades the quality of incident diagnosis but does not break the system. Core alerts still fire, Slack still gets notifications, runbook links still work. LLM diagnosis is an enhancement, not a critical dependency.

Escalate only if LLM errors are causing on-call engineers to miss critical context during a simultaneous infrastructure incident.
