# Runbook: LLMHighErrorRate

**Alert:** LLMHighErrorRate | **Severity:** Warning
**Meaning:** Over 10% of LLM API calls are failing.

## Steps
```bash
docker logs ragservice --tail=100
```bash

## Common Causes
GROQ_API_KEY expired, Groq rate limit hit, Groq API outage.

## Fix
Verify key at console.groq.com. If Groq is down, check status.groq.com — system falls back to raw log delivery automatically.
