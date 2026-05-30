# Runbook: LokiDown

**Alert:** LokiDown | **Severity:** Critical
**Meaning:** Loki unreachable for 2 minutes. Logs not being stored.

## Steps
```bash
docker logs loki --tail=50
docker compose up -d loki
curl http://localhost:3100/ready
```bash

## Fix
Restart Loki. If corrupt WAL prevents startup, remove the loki_data volume (loses historical logs) and restart.
