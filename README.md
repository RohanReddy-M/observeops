# ObserveOps Platform

Production-grade DevOps platform deployed on AWS. Demonstrates infrastructure ownership, CI/CD maturity, observability, and reliability engineering.

**Live:** https://secureship.click

---

## Architecture

```
Internet
    │
    ▼
Route 53 (DNS: secureship.click)
    │
    ▼
AWS ALB (HTTPS:443, HTTP:80) ─── public subnet
    │
    │  path-based routing:
    │  /api/*      → SecureShip:8001
    │  /status/*   → StatusService:8002
    │  /grafana/*  → Grafana:3000
    │
    ▼
Private Subnet
    ├── EC2: App Server (t3.small)
    │       ├── secureship (Docker, :8001)
    │       ├── statusservice (Docker, :8002)
    │       ├── nginx (Docker, :80)
    │       ├── node-exporter (:9100)
    │       └── promtail (log shipper)
    │
    └── EC2: Observability Server (t3.small)
            ├── prometheus (:9090)
            ├── grafana (:3000)
            ├── loki (:3100)
            └── alertmanager (:9093)

VPC: 10.0.0.0/16
  Public:  10.0.1.0/24, 10.0.2.0/24 (ALB, NAT Gateway)
  Private: 10.0.3.0/24, 10.0.4.0/24 (EC2 instances)
```

## Infrastructure

| Component | Tool | Why |
|-----------|------|-----|
| Infrastructure | Terraform | Reproducible, version-controlled infra |
| Compute | EC2 t3.small | Cost-efficient, full control |
| Networking | Custom VPC | Security: private subnets, controlled ingress |
| Load Balancer | AWS ALB | HTTPS termination, path routing, health checks |
| DNS | Route 53 | Managed DNS with health check failover |
| Registry | AWS ECR | Private Docker registry, IAM-controlled access |
| Auth | OIDC | No static credentials in CI/CD |

## Services

### SecureShip API (Python/FastAPI)
Shipment management API with full observability.
- `GET /api/ships` - list ships
- `GET /api/ships/{id}` - get ship
- `POST /api/ships` - create ship
- `GET /health` - health check
- `GET /metrics` - Prometheus metrics

### StatusService (Python/Flask)
System health and incident simulation service.
- `GET /status` - system status
- `POST /load?duration=30` - generate CPU load (for scaling demo)
- `GET /fail` - simulate failures (set FAILURE_RATE=0.5 for 50% errors)

## Observability

### Metrics (Prometheus + Grafana)
Four dashboards:
1. **Service Health**: request rate, error rate, p99 latency, pod count
2. **Infrastructure**: CPU, memory, disk per EC2 instance
3. **Deployment Tracking**: vertical annotations at each deployment
4. **Log Volume**: log lines per minute, error log rate

### Logs (Loki + Promtail)
- JSON structured logs from all containers
- Queryable in Grafana with LogQL
- Correlated with metrics on same dashboard

### Alerts (AlertManager → Slack)
| Alert | Condition | Severity |
|-------|-----------|----------|
| ServiceDown | up == 0 for 1m | critical |
| HighErrorRate | 5xx > 5% for 2m | warning |
| CriticalErrorRate | 5xx > 25% for 1m | critical |
| HighLatency | p99 > 2s for 3m | warning |
| HighCPU | CPU > 80% for 5m | warning |
| DiskSpaceLow | disk > 75% | warning |
| NoLogsReceived | no logs for 5m | warning |

## CI/CD Pipeline

```
Push to any branch
    └── test → build Docker image

Push to develop
    └── test → build → push to ECR (tagged: sha, branch)

Push to main
    └── test → build → push to ECR → [manual approval] → deploy to EC2
            → post-deploy health check
            → automatic rollback if health check fails
            → Grafana deployment annotation
```

Authentication: GitHub OIDC → AWS IAM role (no static credentials)

## Incident Simulations

Documented post-mortems in `docs/incidents/`:

| Incident | How to Trigger | What You Learn |
|----------|---------------|----------------|
| OOMKilled | Set memory limit to 50MB, run load | Memory monitoring, limit tuning |
| Failed deployment + rollback | Push bad image | CI/CD safety nets |
| ALB health check failure | Stop container | Load balancer behavior |
| Disk full | `dd if=/dev/zero of=/tmp/fill bs=1M count=8000` | Disk alerting |
| DNS failure | Edit /etc/hosts | Silent failure detection |

## Local Development

```bash
# Start everything locally
docker compose up -d

# View logs
docker compose logs -f secureship

# Test SecureShip
curl http://localhost:8001/api/ships

# Simulate 50% failure rate
FAILURE_RATE=0.5 docker compose up statusservice

# Generate CPU load
curl -X POST http://localhost:8002/load?duration=30

# Access Grafana
open http://localhost:3000  # admin/observeops123
```

## Deployment

### First time setup
```bash
# 1. Provision infrastructure
cd terraform
terraform init
terraform plan
terraform apply

# 2. SSH to app server (via SSM or bastion)
# 3. Run install script
bash scripts/install.sh

# 4. Deploy application
bash scripts/deploy.sh --local
```

### Subsequent deployments
Push to `main` branch → automatic via GitHub Actions

### Rollback
```bash
bash scripts/deploy.sh --rollback
```

## Cost

| Resource | Cost/month (approx) |
|----------|-------------------|
| EC2 t3.small × 2 | ~₹2,400 |
| ALB | ~₹1,200 |
| NAT Gateway | ~₹2,500 |
| Route 53 | ~₹50 |
| ECR storage | ~₹100 |
| **Total** | **~₹6,250** |

**Cost optimization**: Destroy when not in use: `terraform destroy`

## Architecture Decisions

**Why EC2 over EKS?** EKS control plane alone costs ~₹6,000/month. EC2 with Docker Compose gives full control and is production-representative for single-service deployments. Kubernetes adds value at scale, not for 2-service platforms.

**Why Loki over ELK?** Loki requires ~300MB RAM vs ELK's 4GB minimum. For a t3.small with 2GB RAM, Loki is the pragmatic choice. Same querying capability for our use case.

**Why private subnets?** EC2 instances have no public IPs. The only ingress is through the ALB. If an instance is compromised, the attacker cannot exfiltrate data directly to the internet without going through the ALB (which we control).

**Why separate observability server?** If monitoring runs on the same host as the app, a CPU spike on the app degrades your monitoring. Monitoring must be independent to be trustworthy.
