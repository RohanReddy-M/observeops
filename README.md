# ObserveOps Platform

Production-grade DevOps + MLOps platform on AWS. Demonstrates infrastructure ownership, CI/CD maturity, full-stack observability, AI-assisted incident response, and LLMOps.

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
AWS ALB (HTTP:80) ──────────────── public subnet
    │
    │  path-based routing:
    │  /api/*      → SecureShip:8001
    │  /status/*   → StatusService:8002
    │  /ai/*       → RAGService:8003
    │  /grafana/*  → Grafana:3000
    │
    ▼
Private Subnet
    ├── EC2: App Server (t3.small)
    │       ├── secureship    (FastAPI, :8001)
    │       ├── statusservice (Flask,   :8002)
    │       ├── ragservice    (FastAPI, :8003)  ← AI pipeline
    │       ├── nginx         (reverse proxy, :80)
    │       └── promtail      (log shipper → Loki)
    │
    └── EC2: Observability Server (t3.small)
            ├── prometheus   (:9090)
            ├── grafana      (:3000)
            ├── loki         (:3100)
            ├── alertmanager (:9093)
            └── node-exporter(:9100)

VPC: 10.0.0.0/16
  Public:  10.0.1.0/24, 10.0.2.0/24  (ALB, NAT Gateway)
  Private: 10.0.3.0/24, 10.0.4.0/24  (EC2 instances — no public IPs)
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
Flask service with built-in failure and load simulation. Used to trigger real alerts.

| Endpoint | Description |
|----------|-------------|
| `GET /status` | System status |
| `POST /load?duration=30` | Generate CPU load (triggers HighCPU alert) |
| `GET /fail` | Simulate failures (set `FAILURE_RATE=0.5` for 50% errors) |

### RAGService — `apps/ragservice/`
AI-powered incident response assistant. Answers natural-language questions about your infrastructure using Retrieval-Augmented Generation.

**How it works:**
1. Documents (runbooks, incident logs, architecture notes) are embedded with `all-MiniLM-L6-v2` and stored in a FAISS vector index
2. On each query, the top-4 most similar chunks are retrieved
3. A LangGraph agent grades relevance — if docs are relevant, the Groq LLM generates a grounded answer; if not, it says "I don't have context" instead of hallucinating
4. All LLM calls are tracked with Prometheus metrics (latency, errors, grounding rate)

| Endpoint | Description |
|----------|-------------|
| `POST /query` | Ask a question about your infrastructure |
| `POST /ingest` | Add documents to the knowledge base |
| `GET /health` | Health check (includes `vector_store_ready`) |
| `GET /metrics` | LLMOps Prometheus metrics |

**Example:**
```bash
curl -X POST http://localhost:8003/query \
  -H "Content-Type: application/json" \
  -d '{"question": "What do I do when SecureShip goes down?"}'
```

**Stack:** LangChain 0.3 · LangGraph 0.2 · FAISS · sentence-transformers · Groq (llama-3.1-8b-instant)

---

## Infrastructure — `terraform/`

```
terraform/
├── main.tf              # Root: calls all modules, ECR repos
├── variables.tf
├── outputs.tf
└── modules/
    ├── vpc/             # VPC, subnets, IGW, NAT Gateway, route tables
    ├── security/        # Security groups (ALB, App, Observability)
    ├── compute/         # EC2 instances, IAM role, SSH key pair
    │   ├── user_data_app.sh   # App server bootstrap (Docker + services)
    │   └── user_data_obs.sh   # Obs server bootstrap (monitoring stack)
    └── alb/             # Application Load Balancer + Route53 A record
```

**Security hardening:**
- EC2 instances in **private subnets** — no public IPs, no direct internet access
- IMDSv2 enforced on all EC2 instances (blocks SSRF credential theft)
- Secrets fetched from **SSM Parameter Store** at boot (never in user data or git)
- IAM roles scoped to minimum permissions (ECR pull, SSM read, CloudWatch write)
- OIDC authentication in CI/CD — zero static AWS credentials

---

## Observability

### Metrics — Prometheus + Grafana
Two pre-provisioned dashboards (auto-load on container start):

**Services Overview** (`monitoring/grafana/dashboards/services_overview.json`)
- Service up/down status (stat panels with color coding)
- Request rate per service (req/s over time)
- Error rate % with threshold markers (5% = warning, 25% = critical)
- p50/p99 latency per service
- CPU, memory, disk gauges

**LLM & RAG Metrics** (`monitoring/grafana/dashboards/llm_metrics.json`)
- Total RAG queries and grounded response rate
- LLM API error rate (alert at 10%)
- p50/p95/p99 LLM response latency
- Grounded vs ungrounded answer distribution (donut chart)
- Vector store document count over time

### Logs — Loki + Promtail
- JSON structured logs from all containers (uniform format across services)
- Labels: `container`, `level`, `service`
- Queryable with LogQL in Grafana

### Alerts — AlertManager
| Alert | Condition | Severity |
|-------|-----------|----------|
| ServiceDown | `up == 0` for 1m | critical |
| HighErrorRate | 5xx > 5% for 2m | warning |
| CriticalErrorRate | 5xx > 25% for 1m | critical |
| HighLatency | p99 > 2s for 3m | warning |
| HighCPU | CPU > 80% for 5m | warning |
| DiskSpaceLow | disk < 25% free | warning |
| DiskSpaceCritical | disk < 10% free | critical |
| NoLogsReceived | no logs for 5m | warning |
| **LLMHighErrorRate** | LLM errors > 10% for 2m | warning |
| **LLMHighLatency** | LLM p95 > 15s for 3m | warning |
| **RAGHighUngroundedRate** | ungrounded > 50% for 5m | warning |
| **RAGServiceDown** | ragservice up == 0 for 1m | critical |

---

## CI/CD Pipeline — `.github/workflows/deploy.yml`

```
Push to any branch
    └── [Job 1] test — pytest, docker build verification

Push to develop / main
    └── [Job 2] security-scan (runs after test)
            ├── Trivy — CVE scan of all dependencies
            ├── Bandit — Python SAST (fails on HIGH severity)
            └── TruffleHog — git history secret scan

    └── [Job 3] build-push (needs: test + security-scan)
            ├── Build SecureShip → push to ECR
            ├── Build StatusService → push to ECR
            └── Build RAGService → push to ECR (cached, ~2GB image)

Push to main only:
    └── [Job 4] deploy-production (manual approval gate)
            ├── SSH to EC2, run rolling deploy script
            ├── Smoke-test 7 endpoints
            ├── Auto-rollback if any health check fails
            └── Post deployment annotation to Grafana
```

**Authentication:** GitHub OIDC → AWS IAM role. Zero static credentials anywhere.
**Token scope:** `contents: read`, `id-token: write`, `security-events: write` only.

---

## RAG Quality Evaluation — `scripts/eval_rag.py`

Automated test suite that measures answer quality against known questions. Run in CI to catch regressions when prompts or documents change.

```bash
python scripts/eval_rag.py                          # test localhost
python scripts/eval_rag.py --url http://host:8003   # test deployed instance
python scripts/eval_rag.py --min-score 0.6          # stricter threshold
```

Exit 0 = pass (CI-safe). Exit 1 = quality below threshold.

---

## Local Development

```bash
# Copy env template and add your Groq API key (free at console.groq.com)
cp .env.example .env

# Start all 11 services
docker compose up -d

# Test the AI assistant
curl -X POST http://localhost:8003/query \
  -H "Content-Type: application/json" \
  -d '{"question": "What should I do when SecureShip goes down?"}'

# Open Grafana (auto-loaded dashboards)
# http://localhost:3000  →  admin / observeops123

# Run tests
pytest apps/secureship/tests/ -v
pytest apps/ragservice/tests/ -v

# Evaluate RAG quality
python scripts/eval_rag.py

# Simulate incidents
bash scripts/incident.sh kill       # stops SecureShip → triggers ServiceDown alert
bash scripts/incident.sh errors     # 50% error rate  → triggers HighErrorRate alert
bash scripts/incident.sh disk       # fills disk       → triggers DiskSpaceCritical alert
bash scripts/incident.sh recover    # cleanup all
```

---

## AWS Deployment

### First time
```bash
# 1. Create Terraform backend (one-time)
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

# 3. Provision infrastructure
cd terraform && terraform init && terraform apply

# Outputs: ALB DNS name, ECR URLs, server IPs
```

### Subsequent deploys
Push to `main` → CI/CD handles it automatically (after approval).

### Rollback
```bash
bash scripts/deploy.sh --rollback
```

### Stop billing (when not interviewing)
```bash
terraform destroy    # destroys EC2, ALB, NAT Gateway — stops most charges
```

---

## Architecture Decisions

**Why EC2 over EKS?** EKS control plane = ₹6,000/month minimum. EC2 + Docker Compose demonstrates the same operational concepts (health checks, rolling deploys, service discovery via container names) at ₹600/month.

**Why FAISS over Pinecone?** FAISS is free, runs in-process, no network dependency. Pinecone is a managed service — better at scale but adds cost and a dependency. For a knowledge base of 50-200 documents, FAISS is the right tradeoff.

**Why Groq over OpenAI?** Groq hosts open-source Llama 3 on custom silicon. Free tier, ~200 tok/s, no data retention. The RAGService is provider-agnostic — swapping to OpenAI is a one-line change.

**Why separate observability server?** If Prometheus runs on the same host as the app, a CPU spike on the app degrades your monitoring at the exact moment you need it most. Monitoring must be independent to be trustworthy.

**Why LangGraph over a simple LangChain chain?** LangGraph models the pipeline as a state machine with conditional edges. The relevance-grading node routes to a "no context" fallback instead of generating hallucinated answers. This is the correct production pattern — observable, debuggable, and safe.

**Why IMDSv2?** SSRF vulnerabilities allow attackers to make requests to the EC2 metadata endpoint (169.254.169.254) and steal IAM credentials. IMDSv2 requires a session token that can't be forged via SSRF.
