# Runbook: HighCPUUsage

**Alert:** `HighCPUUsage` | **Severity:** Warning
**Meaning:** CPU above 80% sustained for 5 minutes on an EC2 instance.

---

## Immediate Steps

```bash
top -b -n1 | head -20           # find top process
docker stats --no-stream        # find top container
docker logs <container> --tail=100
```

## Common Causes

| Cause | Evidence | Fix |
|---|---|---|
| Traffic spike | High request rate in Grafana | nginx rate limiting handles bursts |
| RAGService model loading | ragservice CPU spike on startup | Normal — resolves in 30-60s |
| Runaway loop after bad deploy | CPU stuck at 100% after deploy | Roll back image |
| Disk I/O bottleneck | CPU wait high in top | Check disk space |

## Fix

Restart the offending container. If sustained — check for code bug introduced in recent deploy.

## Note on RAGService

RAGService loads an 80 MB embedding model on startup. CPU spikes to 80-100% for ~30 seconds then drops. This is expected and the alert should self-resolve within 2 minutes.
