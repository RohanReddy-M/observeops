# Runbook: HighErrorRate

**Alert:** `HighErrorRate` (>5%) / `CriticalErrorRate` (>25%) | **Severity:** Warning / Critical
**Meaning:** More than 5% of HTTP requests are returning 5xx errors.
**Environment:** Docker Compose on EC2

---

## Step 0 — Quantify before acting

High error rate has wildly different causes. The rate tells you urgency:

| Rate | Meaning | Urgency |
|------|---------|---------|
| 5-15% | Partial degradation — some requests failing | Investigate, don't panic |
| 15-50% | Significant degradation — majority of users affected | Act quickly |
| >50% | Service effectively down | Treat as ServiceDown |

```bash
# What is the current error rate?
curl -s "http://localhost:9090/api/v1/query?query=rate(http_requests_total{status=~'5..'}[5m])/rate(http_requests_total[5m])" \
  | python3 -m json.tool
```

---

## Step 1 — Find which endpoint is failing

Not all endpoints are equal. A failing `/metrics` is irrelevant. A failing `/api/v1/ships` is critical.

```bash
# Check logs for 500 errors — what endpoint?
sudo docker logs secureship --tail=100 2>&1 | grep '"status_code": 5'

# Get the Python traceback
sudo docker logs secureship --tail=200 2>&1 | grep -A 10 "Traceback\|Error:" | head -40
```

---

## Step 2 — Diagnose by root cause

### Root Cause A — Bad deploy introduced a bug

Evidence: Error rate spiked at the exact time of the last deploy.

```bash
# When did errors start vs when was the last deploy?
sudo git -C /opt/observeops log --oneline --since="2 hours ago"
sudo docker logs secureship --tail=200 --timestamps 2>&1 | grep "status_code.*5" | head -5
```

Roll back immediately, investigate on a branch:
```bash
# Get previous image
sudo docker images | grep secureship
# Redeploy will use the current local image — push a revert commit to trigger CI/CD
```

### Root Cause B — DynamoDB connectivity or throttling

Evidence: Errors contain "DynamoDB", "ResourceNotFoundException", "ProvisionedThroughputExceededException"

```bash
sudo docker logs secureship --tail=100 2>&1 | grep -i "dynamodb\|throughput\|throttl"

# Test DynamoDB connectivity from the container
sudo docker exec secureship python3 -c "
import boto3
table = boto3.resource('dynamodb', region_name='ap-south-1').Table('observeops-ships')
print(table.scan(Limit=1))
"
```

For throttling: DynamoDB PAY_PER_REQUEST auto-scales but has a brief warmup period. Wait 60 seconds, check if errors are decreasing.

### Root Cause C — External dependency down (Groq API for RAGService)

Evidence: Errors on `/ai/*` endpoints, "Connection error" in logs

```bash
sudo docker logs ragservice --tail=50 2>&1 | grep -i "groq\|connection\|error"

# Test Groq directly
curl -s --max-time 5 https://api.groq.com/health || echo "UNREACHABLE"
```

If Groq is down: check status.groq.com. The system falls back gracefully — LLM unavailable but other endpoints still work.

### Root Cause D — Application bug (unhandled exception)

Evidence: Specific endpoint always fails, Python traceback in logs

```bash
sudo docker logs secureship --tail=200 2>&1 | grep -B2 -A15 "Traceback"
```

Fix the code and redeploy. Do not restart without fixing — it will immediately return 500 again.

---

## Step 3 — Verify recovery

```bash
# Error rate should drop to near 0 after fix
curl -s "http://localhost:9090/api/v1/query?query=rate(http_requests_total{status=~'5..', job='secureship'}[2m])" \
  | python3 -m json.tool

# Test the specific failing endpoint manually
curl -sv http://localhost:8001/api/v1/ships 2>&1 | grep "< HTTP"
```

---

## Prevention

Every error rate incident should end with a test case that would have caught it. If a code bug reached production and caused 500s — the CI test suite has a gap. Add the test, not just the fix.
