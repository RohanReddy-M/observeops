# Runbook: HighLatency

**Alert:** `HighLatency` | **Severity:** Warning
**Meaning:** p99 latency above 2 seconds for 3 minutes.
**Environment:** Docker Compose on EC2

---

## Step 0 — Understand what p99 means before acting

p99 = the 99th percentile. If p99 is 2 seconds, it means 1 in 100 requests takes 2+ seconds. This is NOT average latency. A single slow endpoint or a single slow user can drive p99 high.

```bash
# What is current p99 latency by endpoint?
# In Grafana: histogram_quantile(0.99, rate(http_request_duration_seconds_bucket{job="secureship"}[5m]))

# Is it all endpoints or a specific one?
# histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[5m])) by (endpoint)
```

Note: `/ai/*` endpoints (RAGService) are expected to be slow (5-30s for LLM calls). HighLatency alert should not fire for AI endpoints. If it is — check the alert filter.

---

## Step 1 — Find the slow endpoint

```bash
# Access logs show response times
sudo docker logs nginx --tail=200 2>&1 | python3 -c "
import sys, json
for line in sys.stdin:
    try:
        d = json.loads(line)
        if float(d.get('request_time', 0)) > 1.0:
            print(d.get('request_time'), d.get('uri'), d.get('status'))
    except: pass
" | sort -rn | head -20
```

---

## Step 2 — Diagnose by root cause

### Root Cause A — DynamoDB latency

Evidence: Slow requests correlate with DynamoDB calls. Latency is consistent (not spiky).

```bash
# Test DynamoDB response time
time sudo docker exec secureship python3 -c "
import boto3, time
t = boto3.resource('dynamodb', region_name='ap-south-1').Table('observeops-ships')
start = time.time()
t.scan()
print(f'DynamoDB scan: {(time.time()-start)*1000:.0f}ms')
"
```

DynamoDB in ap-south-1 from EC2 in the same region should be <10ms. If it's >100ms:
- Table might be throttled (check AWS console)
- Network issue between EC2 and DynamoDB VPC endpoint
- Consider adding a VPC endpoint for DynamoDB (no NAT gateway needed)

### Root Cause B — EC2 CPU pressure causing request queuing

Evidence: Latency spike correlates with CPU spike in Grafana.

```bash
top -b -n1 | head -10
sudo docker stats --no-stream
```

If CPU is high, requests are queuing behind each other. Find and fix the CPU issue first (see high-cpu.md).

### Root Cause C — Memory pressure causing garbage collection pauses

Evidence: Latency spikes are brief and periodic, not sustained.

```bash
sudo docker stats <service_name> --no-stream
```

If memory is near the container limit, Python's garbage collector runs more frequently and causes pause spikes. Increase memory limit or fix the memory leak.

### Root Cause D — External API slow (Groq for RAGService)

Evidence: Only `/ai/*` endpoints are slow.

```bash
# Measure Groq API latency directly
time curl -s -X POST https://api.groq.com/openai/v1/chat/completions \
  -H "Authorization: Bearer $GROQ_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"llama-3.1-8b-instant","messages":[{"role":"user","content":"hi"}]}' \
  > /dev/null
```

If Groq is slow: check status.groq.com. Nothing to do except wait — or switch to a different Groq model with lower latency.

### Root Cause E — Traffic spike causing resource contention

Evidence: Latency correlates with request rate spike.

Not a bug. Options:
1. nginx rate limiting is in place — check if it's configured correctly
2. Identify the expensive query and optimize it
3. Add caching for frequently requested data

---

## Prevention

Latency issues are almost always caught in load testing before they happen in production. Add a load test step to CI that measures p99 under synthetic traffic. If p99 exceeds your SLO threshold in the test — fail the build.
