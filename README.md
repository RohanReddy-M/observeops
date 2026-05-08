# ObserveOps

Three containerized services running on AWS behind an ALB, with a full observability stack and an AI assistant for incident response. Infrastructure is code, deployments are automated, and the monitoring runs on a separate host from the apps it watches.

**Live:** https://secureship.click

![CI/CD](https://github.com/RohanReddy-M/observeops/actions/workflows/deploy.yml/badge.svg)

---

## Architecture

```
Internet
    │
    ▼
Route53 (secureship.click)
    │
    ▼
ALB  ─── HTTPS :443 (ACM cert)  /  HTTP :80 → redirect
    │
    │  /api/*      → secureship   :8001
    │  /status/*   → statusservice:8002
    │  /ai/*       → ragservice   :8003
    │  /grafana/*  → grafana      :3000
    │
    ▼ private subnet (no public IPs)
    ├── EC2: app server
    │       ├── secureship      FastAPI
    │       ├── statusservice   Flask
    │       ├── ragservice      FastAPI + LangGraph
    │       ├── nginx           reverse proxy
    │       └── promtail        ships logs to Loki
    │
    └── EC2: observability server
            ├── prometheus
            ├── grafana
            ├── loki
            ├── alertmanager
            └── node-exporter
```

Observability runs on a separate host so a CPU spike on the app doesn't degrade monitoring at the exact moment you need it.

---

## Services

**SecureShip** (`apps/secureship/`) — FastAPI shipment API, exposes Prometheus metrics on `/metrics`.

**StatusService** (`apps/statusservice/`) — Flask service with endpoints to simulate load and failures, useful for triggering real alerts.

```bash
curl -X POST http://localhost:8002/load?duration=30  # spike CPU
curl http://localhost:8002/fail                      # 500 errors
```

**RAGService** (`apps/ragservice/`) — answers questions about your infrastructure by querying a FAISS vector store built from runbooks and incident notes. Uses a LangGraph agent to grade relevance before passing to Groq — so it returns "I don't have context for that" instead of hallucinating.

```bash
curl -X POST http://localhost:8003/query \
  -H "Content-Type: application/json" \
  -d '{"question": "what do i do when secureship goes down?"}'
```

Stack: LangChain · LangGraph · FAISS · sentence-transformers · Groq (llama-3.1-8b-instant)

---

## Infrastructure (`terraform/`)

```
modules/
├── vpc/       VPC, subnets, IGW, NAT Gateway, route tables
├── security/  security groups
├── compute/   EC2 instances, IAM role, SSM access
└── alb/       ALB, ACM cert + DNS validation, Route53 records
```

- EC2 in private subnets, no public IPs
- IMDSv2 enforced on all instances
- Secrets in SSM Parameter Store, never in code or user data
- IAM roles scoped to minimum permissions
- CI/CD uses OIDC — no static AWS credentials anywhere

---

## CI/CD (`.github/workflows/deploy.yml`)

```
push to any branch
  └── test: pytest + docker build smoke test

push to main/develop
  ├── security-scan: Trivy (CVEs) · Bandit (SAST) · TruffleHog (secrets in git history)
  ├── build-push: builds all three images, pushes to ECR
  └── deploy: SSM Run Command → rolling deploy → smoke test 7 endpoints → auto-rollback on failure
```

Deploy uses SSM, not SSH — EC2 is in a private subnet with no open inbound ports.

Build and deploy are skipped automatically when infra is down (no `EC2_INSTANCE_ID` secret set).

---

## Observability

**Prometheus + Grafana** — two provisioned dashboards: service health (request rate, error %, p50/p99 latency) and LLM metrics (grounding rate, LLM latency, error rate).

**Loki + Promtail** — structured JSON logs from all containers, queryable with LogQL.

**AlertManager** — 12 alert rules across services, disk, latency, and LLM quality.

---

## Kubernetes (`kubernetes/`)

EKS-ready manifests. Also runs locally with `kind`.

```
Ingress → secureship (2–10 pods, HPA on CPU+memory)
        → statusservice (2 pods)
        → ragservice (1–3 pods, HPA on CPU)

Monitoring: Prometheus, Grafana, Loki (all PVC-backed)
```

RAGService runs on a separate node group (`t3.large`, spot) with a `NoSchedule` taint — PyTorch needs the memory and you don't want app pods competing for it.

```bash
kind create cluster --name observeops
kubectl apply -f kubernetes/namespace.yaml
kubectl apply -f kubernetes/apps/
kubectl apply -f kubernetes/monitoring/
kubectl apply -f kubernetes/ingress/ingress.yaml
kubectl get hpa -n observeops
```

---

## Running locally

```bash
cp .env.example .env   # add GROQ_API_KEY (free at console.groq.com)
docker compose up -d

# Grafana: http://localhost:3000  →  admin / observeops123

pytest apps/secureship/tests/ -v
pytest apps/ragservice/tests/ -v
python scripts/eval_rag.py         # RAG quality score
```

---

## AWS deployment

```bash
# first time
cd terraform && terraform init && terraform apply

# subsequent: push to main → CI/CD handles it

# cost control
bash scripts/infra-down.sh   # destroys EC2/ALB/NAT, keeps Route53 (~₹42/month idle)
bash scripts/infra-up.sh     # rebuilds, triggers deploy
```

Route53 zone is kept on destroy to avoid NS record changes — deleting and recreating the zone changes the nameservers, which breaks DNS globally for days until caches expire.
