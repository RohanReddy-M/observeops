# Runbook: ServiceDown

**Alert:** `ServiceDown`
**Severity:** Critical
**Meaning:** Prometheus cannot scrape the target — the service is completely unreachable.

---

## Immediate Steps

```bash
# 1. Check if the container is running
docker ps | grep <service_name>

# 2. If not running — check why it exited
docker logs <service_name> --tail=50

# 3. Restart the container
docker compose -f /opt/observeops/docker-compose.yml up -d <service_name>

# 4. Verify it came back
curl http://localhost:<port>/health
```

## Common Causes

| Cause | Evidence | Fix |
|---|---|---|
| Container crashed (OOM) | `docker logs` shows OOM killed | Increase memory limit or fix memory leak |
| Bad deploy (code error) | `docker logs` shows exception on startup | Roll back: `docker compose up -d` with previous image tag |
| Disk full | `df -h` shows 100% | `docker system prune` to free space |
| Port conflict | `docker logs` shows "port already in use" | Kill conflicting process: `lsof -i :<port>` |
| EC2 instance issue | SSH/SSM shows instance unresponsive | Check EC2 console, reboot if needed |

## Escalation

If the service does not recover within 5 minutes:
1. Check EC2 instance health in AWS console
2. Check ALB target group health
3. If all targets unhealthy — consider running `make infra-up` to rebuild

## Prevention

- Monitor disk space proactively (DiskSpaceLow alert fires at 25% free)
- Set container memory limits in docker-compose.yml
- Auto-rollback in deploy.sh handles bad deploys automatically
