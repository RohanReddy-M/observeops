# ObserveOps

Three containerized services running on AWS behind an ALB, with a full observability stack, a DynamoDB-backed data layer, and an event-driven AI assistant for incident response. Infrastructure is code, deployments are automated, and monitoring runs on a separate host from the apps it watches.

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
    │       ├── secureship      FastAPI + DynamoDB
    │       ├── statusservice   Flask
    │       ├── ragservice      FastAPI + LangGraph + FAISS
    │       ├── nginx           reverse proxy + rate limiting
    │       └── promtail        ships logs to Loki
    │
    └── EC2: observability server
            ├── prometheus
            ├── grafana
            ├── loki
            ├── alertmanager ──→ Lambda (Function URL, no API Gateway)
            └── node-exporter

Event-driven incident response:
    AlertManager fires → Lambda Function URL
        └── Lambda queries RAGService (LangGraph + FAISS + Groq)
              └── publishes diagnosis to SNS topic
                    └── SNS → email / Slack subscribers

Data layer:
    SecureShip ←→ DynamoDB (PAY_PER_REQUEST, point-in-time recovery)
```

Observability runs on a separate host so a CPU spike on the app doesn't degrade monitoring at the exact moment you need it.

---

## Services

**SecureShip** (`apps/secureship/`) — FastAPI shipment API backed by DynamoDB. Falls back to in-memory data for local development (no DynamoDB needed). Exposes Prometheus metrics on `/metrics`. Health endpoint reports which storage backend is active.

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

**Lambda Incident Analyzer** (`apps/lambda/incident_analyzer/`) — serverless function that receives AlertManager webhooks, queries RAGService for diagnosis, and publishes findings to SNS. Also runs on a 5-minute EventBridge schedule for proactive health checks. Uses a Lambda Function URL (no API Gateway needed) so AlertManager posts to it directly.

---

## Infrastructure (`terraform/`)

```
modules/
├── vpc/       VPC, subnets, IGW, NAT Gateway, route tables
├── security/  security groups
├── compute/   EC2 instances, IAM role, SSM access
├── alb/       ALB, ACM cert + DNS validation, Route53 records
├── dynamodb/  ships table (PAY_PER_REQUEST), SSM param with table name
└── lambda/    incident analyzer, Function URL, EventBridge rule, SNS topic
```

- EC2 in private subnets, no public IPs
- IMDSv2 enforced on all instances
- Secrets in SSM Parameter Store, never in code or user data
- IAM roles scoped to minimum permissions
- CI/CD uses OIDC — no static AWS credentials anywhere
- DynamoDB: PAY_PER_REQUEST (zero cost when idle), encrypted at rest, point-in-time recovery enabled

---

## CI/CD (`.github/workflows/deploy.yml`)

```
push to any branch
  └── test: pytest + docker build smoke test

push to main/develop
  ├── security-scan: Trivy (CVEs) · Bandit (SAST) · TruffleHog (secrets in git history)
  ├── build-push: builds all three images, pushes to ECR
  ├── update-k8s-manifests: commits new image tags into kubernetes/apps/ — ArgoCD picks this up
  └── deploy: SSM Run Command → rolling deploy → smoke test 7 endpoints → auto-rollback on failure
```

Deploy uses SSM, not SSH — EC2 is in a private subnet with no open inbound ports.

Build and deploy are skipped automatically when infra is down (no `EC2_INSTANCE_ID` secret set).

---

## Observability

**Prometheus + Grafana** — two provisioned dashboards: service health (request rate, error %, p50/p99 latency) and LLM metrics (grounding rate, LLM latency, error rate).

**Loki + Promtail** — structured JSON logs from all containers, queryable with LogQL.

**AlertManager** — 12 alert rules across services, disk, latency, and LLM quality. Firing alerts are forwarded to the Lambda incident analyzer via Function URL.

---

## Kubernetes + GitOps (`kubernetes/`)

EKS-ready manifests managed by ArgoCD. Also runs locally with `kind`.

```
Ingress → secureship (2–10 pods, HPA on CPU+memory)
        → statusservice (2 pods)
        → ragservice (1–3 pods, HPA on CPU)

Monitoring: Prometheus, Grafana, Loki (all PVC-backed)
```

**GitOps flow:** CI builds an image and commits the new tag into `kubernetes/apps/`. ArgoCD detects the diff and syncs the cluster — CI never touches the cluster directly. If someone manually deletes a deployment, ArgoCD reconciles it back within seconds (`selfHeal: true`).

**App of Apps pattern:** one root ArgoCD Application watches `kubernetes/argocd/apps/` and manages all child applications. Adding a new service is one YAML file.

**NetworkPolicies** (`kubernetes/network-policies/`) — default-deny-all on both ingress and egress. Explicit allow rules for: ingress controller → app pods, Prometheus scraping, intra-namespace communication, and egress to AWS APIs (port 443) and DNS (port 53).

All pods run as non-root with `allowPrivilegeEscalation: false` and all Linux capabilities dropped.

RAGService runs on a dedicated node group (`t3.large`, spot) with a `NoSchedule` taint — PyTorch needs 2 Gi+ and you don't want app pods evicted to make room for it.

```bash
# Local setup
kind create cluster --name observeops
kubectl apply -f kubernetes/namespace.yaml

# Install ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Bootstrap — one command deploys everything via App of Apps
kubectl apply -f kubernetes/argocd/app-of-apps.yaml

# Watch ArgoCD sync all services
kubectl get applications -n argocd
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

SecureShip uses in-memory fallback when `DYNAMODB_TABLE` is not set — no AWS account needed for local development.

---

## AWS deployment

```bash
# first time
cd terraform && terraform init && terraform apply

# subsequent: push to main → CI/CD handles it

# cost control
bash scripts/infra-down.sh   # destroys EC2/ALB/NAT/Lambda, keeps Route53 (~₹42/month idle)
bash scripts/infra-up.sh     # rebuilds, triggers deploy
```

Route53 zone is kept on destroy to avoid NS record changes — deleting and recreating the zone changes the nameservers, which breaks DNS globally for days until caches expire.

DynamoDB uses PAY_PER_REQUEST billing — zero cost when infra is down and no requests are being made.
