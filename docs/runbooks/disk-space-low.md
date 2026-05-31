# Runbook: DiskSpaceLow / DiskSpaceCritical

**Alert:** `DiskSpaceLow` (25% free) / `DiskSpaceCritical` (10% free)
**Severity:** Warning / Critical
**Environment:** Docker Compose on EC2

---

## Step 0 — How much time do you have?

```bash
df -h /
```

| Free space | Urgency |
|------------|---------|
| 25% (warning) | Hours to days — investigate, plan cleanup |
| 10% (critical) | Act now — disk full will crash all services simultaneously |
| <2% | Emergency — services may already be failing with "no space left on device" |

Disk full is one of the worst failure modes because it kills everything at once — Prometheus can't write, Loki can't store logs, Docker can't start containers. Get ahead of it.

---

## Step 1 — Find what is consuming disk

```bash
# Top-level breakdown
du -sh /* 2>/dev/null | sort -rh | head -10

# Docker-specific usage (images, containers, volumes, build cache)
sudo docker system df

# Loki log storage
sudo du -sh /var/lib/docker/volumes/*loki* 2>/dev/null

# Prometheus TSDB storage
sudo du -sh /var/lib/docker/volumes/*prometheus* 2>/dev/null
```

The usual culprits in order of frequency:
1. Old Docker images accumulating after deploys
2. Docker build cache
3. Prometheus TSDB (time-series data, 15-day retention by default)
4. Loki log chunks
5. Application log files

---

## Step 2 — Safe cleanup (do these first, no data loss)

```bash
# Remove stopped containers
sudo docker container prune -f

# Remove unused images (not currently running)
sudo docker image prune -f

# Remove build cache
sudo docker builder prune -f

# Check how much you recovered
df -h /
```

If this recovers enough space (back above 25%) — you're done. Monitor for recurrence.

---

## Step 3 — If still critical after safe cleanup

```bash
# Remove ALL unused images including dangling ones
sudo docker image prune -a -f

# WARNING: This removes images not currently in use
# If you need to roll back to a previous version, those images are gone
# Make sure CI/CD can rebuild from ECR before doing this
```

---

## Step 4 — If disk is full and services are failing

```bash
# Find the largest single files
sudo find / -type f -size +100M 2>/dev/null | sort -k5 -rn | head -10

# If application logs are huge
sudo truncate -s 0 /var/log/observeops/*.log

# Emergency: clear Docker's overlay filesystem (loses container logs)
sudo docker system prune -a -f --volumes
# WARNING: This removes ALL volumes including persistent data (Prometheus, Loki, Grafana)
# Only use this if services are already down and you need to recover the server
```

---

## Prevention

Disk filling up slowly means something is growing without a retention policy.

| Growing item | Permanent fix |
|---|---|
| Docker images | ECR lifecycle policy (already configured — keep 10 images) |
| Prometheus TSDB | 15-day retention already set in docker-compose.yml |
| Loki chunks | Loki retention configured — verify `retention_period` in loki config |
| Build cache | Add `sudo docker builder prune -f` to a weekly cron on the EC2 |
| App logs | Ensure Docker log rotation is configured (max-size, max-file in docker daemon.json) |
