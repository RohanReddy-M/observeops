# Runbook: LokiDown

**Alert:** `LokiDown` | **Severity:** Critical
**Meaning:** Loki has been unreachable for 2+ minutes. Logs are not being stored.
**Environment:** Docker Compose on EC2 (obs server)

---

## Step 0 — Understand the impact

When Loki is down:
- All LogQL queries in Grafana fail silently (dashboards show "no data")
- Promtail is buffering logs locally — it will NOT lose them for a short outage
- LLM Alert Autopilot cannot query logs for diagnosis context
- **Metrics and alerting still work** — Prometheus is unaffected

This is serious but not a system outage. Application traffic is unaffected.

---

## Step 1 — Is Loki actually down or just slow?

```bash
# On the obs server
sudo docker ps | grep loki

# Health check
curl -s http://localhost:3100/ready && echo "LOKI READY" || echo "LOKI DOWN"

# Loki can be "running" but not "ready" — these are different
sudo docker inspect loki --format='Status={{.State.Status}} Health={{.State.Health.Status}}'
```

---

## Step 2 — Read the logs before touching anything

```bash
sudo docker logs loki --tail=50 --timestamps 2>&1
```

Common error patterns:

| Log message | Meaning |
|---|---------|
| `WAL segment corrupted` | Write-ahead log corruption — see Root Cause B |
| `out of memory` | OOM kill — see Root Cause A |
| `permission denied` | Volume mount permissions issue |
| `bind: address already in use` | Port 3100 conflict |
| `compactor` errors | Retention/compaction issue — usually non-fatal |

---

## Step 3 — Diagnose by root cause

### Root Cause A — OOM Kill

```bash
sudo docker inspect loki --format='OOMKilled={{.State.OOMKilled}} ExitCode={{.State.ExitCode}}'
```

If OOMKilled=true:

Loki's memory usage grows with ingestion rate and query load. On a t3.micro this is tight.

```bash
# Check volume size
sudo du -sh /var/lib/docker/volumes/*loki*

# Restart — Loki will recover from its WAL
sudo docker compose -f /opt/observeops/docker-compose.yml restart loki
sleep 10 && curl -s http://localhost:3100/ready
```

If it OOM-kills again within minutes — reduce Loki's ingestion limits or increase EC2 memory.

### Root Cause B — WAL Corruption (unclean shutdown)

Evidence: `WAL segment corrupted` in logs. Happens after a hard instance restart or power loss.

```bash
# Find the WAL location
sudo docker inspect loki --format='{{range .Mounts}}{{if eq .Destination "/loki"}}{{.Source}}{{end}}{{end}}'

# Remove the corrupted WAL — you lose in-flight logs from the last few minutes
sudo docker stop loki
sudo rm -rf <wal_path>/wal/*
sudo docker compose -f /opt/observeops/docker-compose.yml up -d loki
sleep 10 && curl -s http://localhost:3100/ready
```

Historical logs stored in chunks are safe — only the WAL (last few minutes) is lost.

### Root Cause C — Volume full

```bash
df -h
sudo docker system df
```

If disk is full, see disk-space-low.md first. Loki cannot write to a full disk.

### Root Cause D — Port conflict

```bash
sudo ss -tlnp | grep 3100
```

If another process is on port 3100:
```bash
# Find it
sudo lsof -i :3100
# Kill it if it shouldn't be there
sudo kill <pid>
sudo docker compose -f /opt/observeops/docker-compose.yml up -d loki
```

---

## Step 4 — Verify recovery and check for log gaps

```bash
# Loki is ready
curl -s http://localhost:3100/ready

# Promtail is shipping logs again
sudo docker logs promtail --tail=10 2>&1 | grep -i "send\|sent\|flush"

# In Grafana — query logs from the last 30 minutes to confirm
# {job="secureship"} — should show recent entries
```

Check how long Loki was down. If it was down for more than 5 minutes, there's a log gap. Document this in the incident record — if a security or compliance audit asks for logs from that window, they don't exist.

---

## Prevention

- Loki WAL corruption usually means the EC2 was hard-rebooted. Add graceful shutdown handling.
- If Loki keeps OOM-killing, reduce `ingestion_rate_mb` in loki config or move to a larger instance for the obs server.
- Consider enabling Loki's `use_boltdb_shipper` for more resilient storage.
