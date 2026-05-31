# Runbook: HighCPUUsage

**Alert:** `HighCPUUsage` | **Severity:** Warning
**Meaning:** CPU above 80% sustained for 5 minutes on the EC2 instance.
**Environment:** Docker Compose on EC2

---

## Step 0 — Is this actually a problem?

High CPU is not always an incident. Identify before acting.

```bash
# Which container is consuming CPU?
sudo docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}"

# What is the overall system load?
top -b -n1 | head -5
```

Known expected spikes — do NOT restart for these:
- `ragservice` at startup: loads 80MB ML model, CPU spikes 60-90s then drops
- `statusservice` during `/load` endpoint: intentional load test
- Any container during `docker build`: build process is CPU-heavy

If CPU is trending down → monitor, don't act.

---

## Step 1 — Identify the exact source

```bash
# Find which process inside the container is hot
sudo docker exec <container_name> ps aux --sort=-%cpu | head -10

# What is it actually doing?
sudo docker logs <container_name> --tail=50 --timestamps 2>&1

# Is request rate correlated with CPU spike?
# Check Grafana: rate(http_requests_total{job="<service>"}[5m])
```

---

## Step 2 — Diagnose by root cause

### Root Cause A — Traffic spike (legitimate load)

CPU correlates with high request rate in Grafana.

This is not a bug. Options in order of preference:
1. Identify the expensive endpoint — profile it, optimize it
2. Add nginx rate limiting for that endpoint
3. Scale the EC2 instance type (last resort — treats symptom not cause)

Do NOT restart the container. It will immediately be busy again.

### Root Cause B — Runaway process / infinite loop

CPU at 100% but request rate is normal or zero. One process is stuck.

```bash
# Get a thread dump to find the stuck function
sudo docker exec <container_name> kill -3 1
sudo docker logs <container_name> --tail=30
# Look for the same function repeated in the dump
```

Fix the code bug. Then restart:
```bash
sudo docker compose -f /opt/observeops/docker-compose.yml restart <container_name>
```

### Root Cause C — RAGService model loading (expected, self-resolving)

Do nothing. Wait 90 seconds. The alert will resolve on its own.
Restarting makes it worse — creates a new model load spike.

### Root Cause D — Docker build or system process

```bash
ps aux --sort=-%cpu | head -10
```

If it's a system process (`dockerd`, `kthreadd`, etc.) — not an application issue. Monitor.

---

## Prevention

Restarting without finding root cause means this repeats. After every HighCPU incident:
- If traffic-driven: profile the expensive endpoint, add rate limiting
- If runaway process: add a test case that catches the loop
- If expected startup spike: tune the alert threshold for ragservice startup window
