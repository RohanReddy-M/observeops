# ObserveOps Platform

Production-grade DevOps + MLOps platform on AWS. End-to-end ownership: infrastructure provisioning, containerized services, CI/CD, full-stack observability, Kubernetes manifests, and AI-assisted incident response.

**Live:** https://secureship.click &nbsp;|&nbsp; **Stack:** AWS · Terraform · Docker · Kubernetes · GitHub Actions · Python

![CI/CD](https://github.com/RohanReddy-M/observeops/actions/workflows/deploy.yml/badge.svg)

---

## What this covers

| Area | Technology | Detail |
|------|-----------|--------|
| Infrastructure | Terraform | VPC, EC2, ALB, Route53, ACM, ECR, SSM — fully IaC |
| Containers | Docker Compose + Kubernetes | Dev: Compose · Prod-ready: EKS manifests with HPA |
| CI/CD | GitHub Actions | Test → Security scan → Build/push → Deploy → Rollback |
| Auth | OIDC (no static credentials) | GitHub → AWS IAM via OIDC federation |
| Observability | Prometheus + Grafana + Loki | Metrics, dashboards, structured logs, alerting |
| AI / GenAI | RAG pipeline (LangChain + LangGraph + FAISS + Groq) | Grounded incident response assistant |
| Security | IMDSv2, private subnets, SSM Parameter Store, Trivy, Bandit | Defence-in-depth across all layers |

---

## Architecture

```
Internet
    │
    ▼
Route 53 (secureship.click)
    │
    ▼
AWS ALB  ─── HTTPS :443 (ACM cert, TLS 1.3)
    │         HTTP :80  → redirect to HTTPS
    │
    │  Path-based routing:
    │  /api/*      → SecureShip   :8001
    │  /status/*   → StatusService:8002
    │  /ai/*       → RAGService   :8003
    │  /grafana/*  → Grafana      :3000
    │
    ▼ Private Subnet (no public IPs)
    ├── EC2: App Server (t3.small)
    │       ├── secureship    (FastAPI)
    │       ├── statusservice (Flask)
    │       ├── ragservice    (FastAPI + LangGraph)
    │       ├── nginx         (reverse proxy, runtime DNS resolver)
    │       └── promtail      (log shipper → Loki)
    │
    └── EC2: Observability Server (t3.small)
            ├── prometheus   — metrics scrape
            ├── grafana      — dashboards
            ├── loki         — log aggregation
            ├── alertmanager — alert routing
            └── node-exporter— host metrics

VPC: 10.0.0.0/16
  Public:  10.0.1.0/24, 10.0.2.0/24  (ALB, NAT Gateway)
  Private: 10.0.3.0/24, 10.0.4.0/24  (EC2 — unreachable from internet)
```

---

## Kubernetes (EKS-ready) — `kubernetes/`

Full production manifests for running ObserveOps on EKS. Also runs locally with `kind` (free).

```
Internet → AWS ALB (Load Balancer Controller)
              ↓
         Ingress (path-based)
         ├── /ai/*      → ragservice   (1–3 pods, HPA on CPU)
         ├── /status/*  → statusservice (2 pods)
         └── /*         → secureship   (2–10 pods, HPA on CPU + memory)

Monitoring:
  Prometheus → scrapes all pods (PVC-backed)
  Grafana    → dashboards       (PVC-backed)
  Loki       → log aggregation  (PVC-backed)
```

**Design decisions:**
- Spot instances — 70% cost reduction for stateless pods
- Separate `ai-nodes` node group with `NoSchedule` taint — RAGService needs 2 Gi+ for PyTorch; keeps AI workload off app nodes
- `maxUnavailable: 0` rolling updates — zero-downtime deploys
- HPA scale-up: fast (30 s window for secureship) · scale-down: slow (5 min) to prevent thrashing
- All services ClusterIP — no pod directly reachable; all external traffic through Ingress/ALB

```bash
# Run locally (no AWS needed)
kind create cluster --name observeops
kubectl apply -f kubernetes/namespace.yaml
kubectl apply -f kubernetes/apps/
kubectl apply -f kubernetes/monitoring/
kubectl apply -f kubernetes/ingress/ingress.yaml
kubectl get hpa -n observeops
```

---

## Services

### SecureShip API — `apps/secureship/`
FastAPI shipment management service. Primary demo API.

| Endpoint | Description |
|----------|-------------|
| `GET /api/ships` | List all ships |
| `GET /api/ships/{id}` | Get ship by ID |
| `POST /api/ships` | Create ship |
| `GET /health` | Health check |
| `GET /metrics` | Prometheus metrics |

**Metrics exposed:** `http_requests_total`, `http_request_duration_seconds`, `app_info`

### StatusService — `apps/statusservice/`
Flask service with built-in failure and load simulation — used to trigger real alerts.

| Endpoint | Description |
|----------|-------------|
| `GET /status` | System status |
| `POST /load?duration=30` | Generate CPU load (triggers HighCPU alert) |
| `GET /fail` | Simulate failures (set `FAILURE_RATE=0.5` for 50% errors) |

### RAGService — `apps/ragservice/`
AI-powered incident response assistant. Answers natural-language questions about your infrastructure.

**How it works:**
1. Documents (runbooks, incident logs, architecture notes) are embedded with `all-MiniLM-L6-v2` and stored in a FAISS vector index
2. On each query, the top-4 most similar chunks are retrieved
3. A LangGraph agent grades relevance — if docs are relevant, Groq LLM generates a grounded answer; if not, it says "I don't have context" instead of hallucinating
4. All LLM calls tracked with Prometheus metrics (latency, errors, grounding rate)

| Endpoint | Description |
|----------|-------------|
| `POST /query` | Ask a question about your infrastructure |
| `POST /ingest` | Add documents to the knowledge base |
| `GET /health` | Health check (includes `vector_store_ready`) |
| `GET /metrics` | LLMOps Prometheus metrics |

```bash
curl -X POST https://secureship.click/ai/query \
  -H "Content-Type: application/json" \
  -d '{"question": "What do I do when SecureShip goes down?"}'
```

**Stack:** LangChain 0.3 · LangGraph 0.2 · FAISS · sentence-transformers · Groq (llama-3.1-8b-instant)

---

## Infrastructure — `terraform/`

```
terraform/
├── main.tf              # Root module — calls all child modules, ECR repos
├── variables.tf
├── outputs.tf
└── modules/
    ├── vpc/             # VPC, subnets, IGW, NAT Gateway, route tables
    ├── security/        # Security groups (ALB, App, Observability)
    ├── compute/         # EC2 instances, IAM role, key pair
    │   ├── user_data_app.sh   # App server bootstrap
    │   └── user_data_obs.sh   # Observability server bootstrap
    └── alb/             # ALB, ACM cert, Route53 zone + validation records
```

**Security hardening:**
- EC2 in **private subnets** — no public IPs, no direct internet exposure
- IMDSv2 enforced — blocks SSRF-based credential theft via metadata endpoint
- Secrets in **SSM Parameter Store** — never in user data, env files, or git
- IAM roles scoped to minimum permissions (ECR pull, SSM read, CloudWatch write)
- OIDC in CI/CD — zero static AWS credentials in GitHub or anywhere else

---

## CI/CD Pipeline — `.github/workflows/deploy.yml`

```
Push to any branch
    └── [Job 1] test
            ├── pytest (secureship, ragservice)
            └── docker build smoke test

Push to develop / main
    └── [Job 2] security-scan  (needs: test)
            ├── Trivy  — CVE scan of all dependencies
            ├── Bandit — Python SAST (fails on HIGH severity)
            └── TruffleHog — git history secret scan

    └── [Job 3] build-push  (needs: test + security-scan)
            ├── Build SecureShip   → push to ECR
            ├── Build StatusService→ push to ECR
            └── Build RAGService   → push to ECR (layer-cached, ~2 GB image)

Push to main only
    └── [Job 4] deploy-production  (manual approval gate)
            ├── AWS SSM Run Command — no SSH, no open ports
            ├── Rolling deploy + smoke-test (7 endpoints)
            ├── Auto-rollback if any health check fails
            └── Grafana deployment annotation
```

**Auth:** GitHub OIDC → AWS IAM role. No static credentials anywhere.
**Token scope:** `contents: read` · `id-token: write` · `security-events: write` only.

---

## Observability

### Metrics — Prometheus + Grafana
Two pre-provisioned dashboards (auto-load on container start):

**Services Overview**
- Service up/down (stat panels, color-coded)
- Request rate per service (req/s)
- Error rate % with threshold markers (5% warning, 25% critical)
- p50/p99 latency per service
- CPU, memory, disk gauges

**LLM & RAG Metrics**
- Total RAG queries and grounded response rate
- LLM API error rate (alert at 10%)
- p50/p95/p99 LLM response latency
- Grounded vs ungrounded distribution (donut chart)
- Vector store document count

### Logs — Loki + Promtail
- JSON structured logs from all containers
- Labels: `container`, `level`, `service`
- Queryable with LogQL in Grafana

### Alerts — AlertManager
| Alert | Condition | Severity |
|-------|-----------|----------|
| ServiceDown | `up == 0` for 1 m | critical |
| HighErrorRate | 5xx > 5% for 2 m | warning |
| CriticalErrorRate | 5xx > 25% for 1 m | critical |
| HighLatency | p99 > 2 s for 3 m | warning |
| HighCPU | CPU > 80% for 5 m | warning |
| DiskSpaceLow | disk < 25% free | warning |
| DiskSpaceCritical | disk < 10% free | critical |
| NoLogsReceived | no logs for 5 m | warning |
| LLMHighErrorRate | LLM errors > 10% for 2 m | warning |
| LLMHighLatency | LLM p95 > 15 s for 3 m | warning |
| RAGHighUngroundedRate | ungrounded > 50% for 5 m | warning |
| RAGServiceDown | ragservice up == 0 for 1 m | critical |

---

## RAG Quality Evaluation — `scripts/eval_rag.py`

Automated test suite that measures answer quality against known questions. Runs in CI to catch regressions when prompts or documents change.

```bash
python scripts/eval_rag.py                          # test localhost
python scripts/eval_rag.py --url http://host:8003   # test deployed instance
python scripts/eval_rag.py --min-score 0.6          # stricter threshold
```

Exit 0 = pass (CI-safe). Exit 1 = quality below threshold.

---

## Local Development

```bash
cp .env.example .env          # add Groq API key (free at console.groq.com)
docker compose up -d          # starts all 11 services

# Test the AI assistant
curl -X POST http://localhost:8003/query \
  -H "Content-Type: application/json" \
  -d '{"question": "What should I do when SecureShip goes down?"}'

# Grafana: http://localhost:3000  →  admin / observeops123

pytest apps/secureship/tests/ -v
pytest apps/ragservice/tests/ -v
python scripts/eval_rag.py

# Simulate incidents
bash scripts/incident.sh kill      # stop SecureShip → ServiceDown alert
bash scripts/incident.sh errors    # 50% error rate  → HighErrorRate alert
bash scripts/incident.sh disk      # fill disk        → DiskSpaceCritical alert
bash scripts/incident.sh recover   # cleanup
```

---

## AWS Deployment

### First time
```bash
# 1. Terraform state backend (one-time)
aws s3 mb s3://observeops-terraform-state-$(aws sts get-caller-identity --query Account --output text)
aws dynamodb create-table \
  --table-name observeops-terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST

# 2. Store Groq API key in SSM (never in code)
aws ssm put-parameter \
  --name "/observeops/production/groq_api_key" \
  --value "gsk_your_key" \
  --type SecureString

# 3. Provision
cd terraform && terraform init && terraform apply
```

### Subsequent deploys
Push to `main` → CI/CD pipeline handles it automatically (after manual approval).

### Rollback
```bash
bash scripts/deploy.sh --rollback
```

### Cost control
```bash
bash scripts/infra-down.sh   # destroys EC2, ALB, NAT Gateway — near-zero idle cost
bash scripts/infra-up.sh     # rebuilds from scratch, triggers deploy
```

---

## Architecture Decisions

**Why EC2 over EKS for current deployment?** EKS control plane costs ₹6,000+/month. EC2 + Docker Compose demonstrates identical operational concepts (health checks, rolling deploys, service discovery) at ₹600/month. The `kubernetes/` directory has production-ready EKS manifests for when scale justifies the cost.

**Why FAISS over Pinecone?** FAISS is free, runs in-process, no network dependency. For 50–200 documents, FAISS is the right tradeoff. The service is provider-agnostic — switching is a config change.

**Why Groq over OpenAI?** Groq runs open-source Llama 3 on custom silicon. Free tier, ~200 tok/s, no data retention. Provider-agnostic interface — swapping to OpenAI is a one-line change.

**Why separate observability server?** A CPU spike on the app degrades monitoring exactly when you need it most. Monitoring must be independent of what it monitors.

**Why LangGraph over a simple chain?** LangGraph models the pipeline as a state machine with conditional edges. The relevance-grading node routes to a "no context" fallback instead of hallucinating. Observable, debuggable, correct.

**Why IMDSv2?** SSRF vulnerabilities can reach the EC2 metadata endpoint (169.254.169.254) and steal IAM credentials. IMDSv2 requires a signed session token that can't be forged via SSRF.

**Why runtime DNS resolution in nginx?** nginx resolves `upstream` blocks at startup — if a container isn't up yet, nginx crashes. Docker's embedded DNS (`127.0.0.11`) resolves names at request time, so startup order doesn't matter.
