# Runbook: ServiceDown

**Alert:** `ServiceDown` | **Severity:** Critical
**Meaning:** Prometheus cannot scrape the target — the service process has died or is refusing connections.
**Environment:** Docker Compose on EC2 (`/opt/observeops/docker-compose.yml`)

---

## Step 0 — Do NOT restart immediately

Restarting before diagnosis destroys evidence. A crashed container has an exit code, last log lines, and memory state. Once you restart, that context is gone and the incident will repeat.

```bash
# Preserve state first — get exit code
sudo docker inspect <service_name> \
  --format='ExitCode={{.State.ExitCode}} OOMKilled={{.State.OOMKilled}} FinishedAt={{.State.FinishedAt}}'
```

**Exit code meanings:**

| Code | Meaning | What to do |
|------|---------|------------|
| `137` | OOM killed — out of memory | Find the memory leak before restarting |
| `1` | Application exception | Read the traceback — fix the bug first |
| `0` | Clean exit | Should never happen in production — something called shutdown |
| `143` | SIGTERM — graceful shutdown | Deploy or Docker restart triggered this |
| `2` | Bad config or missing env var | Check env vars in docker-compose.yml |

---

## Step 1 — Reconstruct the timeline

Before touching anything, understand what happened.

```bash
# Exact time of death
sudo docker inspect <service_name> --format='{{.State.FinishedAt}}'

# Last 100 log lines with timestamps — look for the error before the crash
sudo docker logs <service_name> --tail=100 --timestamps 2>&1 \
  | grep -E "ERROR|WARN|exception|killed|timeout|refused|traceback" -i

# Was there a deploy just before?
sudo git -C /opt/observeops log --oneline --since="2 hours ago"

# Has this happened before?
sudo docker inspect <service_name> --format='RestartCount={{.RestartCount}}'
```

**The answer changes everything:**
- Crashed right after a deploy → bad code, roll back
- Crashed after a traffic spike → resource exhaustion, investigate before scaling
- Crashed randomly → memory leak or external dependency failure
- Crashed multiple times (RestartCount > 1) → systemic issue, not a one-off

---

## Step 2 — Diagnose by root cause

### Root Cause A — OOM Kill (ExitCode=137, OOMKilled=true)

```bash
# Confirm OOM kill
sudo docker inspect <service_name> --format='{{.State.OOMKilled}}'

# See what memory limit was set
sudo docker inspect <service_name> --format='{{.HostConfig.Memory}}'

# Was memory growing steadily? Check Grafana container memory panel
# Or query Prometheus: container_memory_usage_bytes{name="<service_name>"}
```

Two possibilities:
- Memory grew steadily over hours → **memory leak in code**. Increasing the limit just delays the next crash. Find and fix the leak.
- Memory was stable then spiked suddenly → **traffic burst or large payload**. Increase limit, then optimize.

```bash
# After identifying cause — restart
sudo docker compose -f /opt/observeops/docker-compose.yml up -d <service_name>
```

### Root Cause B — Application Exception (ExitCode=1)

```bash
# Find the Python traceback
sudo docker logs <service_name> 2>&1 | grep -A 15 "Traceback\|Error\|Exception" | tail -30
```

The traceback tells you exactly what failed. Fix the code. Do not restart until you understand the exception — it will crash again in seconds.

### Root Cause C — Bad Deploy (ExitCode=1, crashed after git push)

```bash
# Confirm recent deploy
sudo git -C /opt/observeops log --oneline -3

# Does the new image even start?
sudo docker logs <service_name> 2>&1 | head -20
```

Roll back first, investigate later:

```bash
# Get the previous image tag
sudo docker images observeops/<service_name>

# Roll back by tagging previous image as local and restarting
sudo docker compose -f /opt/observeops/docker-compose.yml up -d <service_name>
```

### Root Cause D — Disk Full (ExitCode=1, "no space left on device")

```bash
df -h
sudo docker system df
```

```bash
# Free space — safe to run
sudo docker system prune -f
sudo docker image prune -a -f
# Then restart
sudo docker compose -f /opt/observeops/docker-compose.yml up -d <service_name>
```

### Root Cause E — External Dependency Down (ExitCode=1, "connection refused")

Service tried to reach DynamoDB, Groq API, or Loki at startup and failed.

```bash
# Test Groq reachability from inside the container
sudo docker run --rm curlimages/curl curl -s --max-time 5 https://api.groq.com/health

# Test DynamoDB from EC2
curl -s --max-time 5 https://dynamodb.ap-south-1.amazonaws.com

# Check if env vars are actually set
sudo docker inspect <service_name> --format='{{range .Config.Env}}{{println .}}{{end}}' \
  | grep -E "GROQ|DYNAMODB|API_KEY"
```

Fix the dependency first. Restarting the service when its dependency is down just creates a crash loop.

---

## Step 3 — Restart only after diagnosing

```bash
sudo docker compose -f /opt/observeops/docker-compose.yml up -d <service_name>

# Wait 30 seconds — does it stay up or crash again?
sleep 30 && sudo docker ps | grep <service_name>

# Check health directly
curl -s http://localhost:<port>/health
```

If it crashes again immediately — you fixed the wrong thing. Go back to Step 2.

---

## Step 4 — Confirm alert resolves in Prometheus

```bash
# Should return 1 within 30 seconds of service coming up
curl -s "http://localhost:9090/api/v1/query?query=up{job='<service_name>'}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['result'])"
```

If still 0 after 60 seconds — the process is running but health endpoint is failing. Check application logs again.

---

## Postmortem required if:

- Service was down longer than 5 minutes
- This is the second occurrence this month (RestartCount pattern)
- User traffic was impacted — check ALB 5xx rate in Grafana
- Root cause was a code bug that reached production

---

## Prevention — fix the system, not just the symptom

| Root cause | Systemic fix |
|---|---|
| OOM kill | Add memory limits in docker-compose.yml + alert before reaching limit |
| Application exception | Add the missing test case to the CI suite |
| Bad deploy | The failing case should have been caught by smoke tests in deploy.sh |
| Disk full | docker system prune in a weekly cron |
| Dependency down | Health check should verify dependency connectivity, not just process liveness |
