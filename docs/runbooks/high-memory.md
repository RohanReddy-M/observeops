# Runbook: HighMemoryUsage

**Alert:** `HighMemoryUsage` | **Severity:** Warning
**Meaning:** Available system RAM below 10% of total.
**Environment:** Docker Compose on EC2 (t3.micro = 1GB RAM)

---

## Step 0 — This is a warning, not an emergency yet

10% of 1GB = 100MB free. You have time to diagnose. Do NOT restart containers randomly — you need to know which one is the problem and why.

```bash
# Overall memory picture
free -m

# Which container is using the most memory?
sudo docker stats --no-stream --format "table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}" | sort -k2 -rh
```

---

## Step 1 — Is memory growing or stable?

A container using 400MB is not a problem if it has always used 400MB. A container that was using 200MB last week and is now at 800MB has a memory leak.

```bash
# Check current vs allocated limit
sudo docker inspect <container_name> \
  --format='Memory limit: {{.HostConfig.Memory}} | Current: {{.State.Status}}'

# In Grafana: look at container_memory_usage_bytes over the past 24 hours
# A hockey stick curve = memory leak
# A flat line = stable, just high
```

---

## Step 2 — Diagnose by container

### RAGService memory growth (most common)

RAGService holds a FAISS vector index in memory. Every document ingested via `/ingest` adds to it. This is expected behavior — the index grows as you add more runbooks.

```bash
sudo docker exec ragservice python3 -c "
from rag_pipeline import pipeline
print(f'Documents in FAISS index: {pipeline.vector_store.index.ntotal}')
"
```

If the index is large: this is working as designed. If you need to reclaim memory, restart ragservice (index is in-memory, will be empty after restart — re-ingest runbooks).

### Prometheus memory growth

Prometheus stores time-series data locally. Its memory grows with the number of metrics and label combinations (cardinality).

```bash
# Check Prometheus memory vs retention
sudo docker exec prometheus du -sh /prometheus
# If WAL is huge → high cardinality or retention set too long
```

### Loki memory growth

Loki buffers log chunks before writing to disk. If a service is logging at very high rate, Loki buffers grow.

```bash
sudo docker logs loki --tail=20 2>&1 | grep -i "memory\|warn\|error"
```

### Generic memory leak check

```bash
# Get memory usage trend for a container (run twice, compare)
sudo docker stats <container_name> --no-stream
sleep 60
sudo docker stats <container_name> --no-stream
# If second reading is significantly higher — active leak
```

---

## Step 3 — Actions by severity

**If 10% free (warning level):** Monitor, identify the growing container, plan a maintenance window.

**If 5% free:** Take action.
```bash
# Safe to clear: Docker build cache
sudo docker builder prune -f

# Safe to clear: Unused images
sudo docker image prune -f

# If RAGService index is too large and not needed:
sudo docker compose -f /opt/observeops/docker-compose.yml restart ragservice
```

**If <2% free (imminent OOM):** Restart the highest-memory container that is not prometheus or loki (losing metrics/logs is worse than losing app state).

---

## Prevention

On a t3.micro (1GB RAM), running this full stack is tight. The long-term fix is:
1. Move the monitoring stack to the obs server (it's already there in production)
2. Set explicit memory limits in docker-compose.yml so one container can't starve others
3. Persist the FAISS index to disk so it survives restarts without re-ingestion
