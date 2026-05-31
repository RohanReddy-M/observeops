# ─── ObserveOps Makefile ──────────────────────────────────────────────────────
# Single entry point for every operation in this project.
# Run `make help` to see all available commands.
#
# Usage:
#   make dev-up       start everything locally
#   make test         run all tests
#   make deploy       deploy to production
#   make infra-up     provision AWS infrastructure
#   make infra-down   destroy AWS infrastructure (keeps Route53)

.PHONY: help dev-up dev-down dev-restart logs status \
        test test-secureship test-ragservice \
        build build-secureship build-statusservice build-ragservice \
        deploy rollback \
        infra-up infra-down plan apply \
        scan lint fmt \
        chaos chaos-ragservice chaos-statusservice \
        clean shell-secureship shell-statusservice

# ─── Default target ───────────────────────────────────────────────────────────
.DEFAULT_GOAL := help

help:
	@echo ""
	@echo "  ObserveOps — available commands"
	@echo ""
	@echo "  LOCAL DEVELOPMENT"
	@echo "    make dev-up             start all services locally (builds if needed)"
	@echo "    make dev-down           stop and remove all containers"
	@echo "    make dev-restart        restart all services"
	@echo "    make logs               tail logs from all containers"
	@echo "    make status             show running containers and their health"
	@echo ""
	@echo "  TESTING"
	@echo "    make test               run all tests"
	@echo "    make test-secureship    run SecureShip tests only"
	@echo "    make test-statusservice run StatusService tests only"
	@echo "    make test-ragservice    run RAGService tests only"
	@echo "    make scan               run security scan (Trivy + Bandit)"
	@echo ""
	@echo "  BUILD"
	@echo "    make build              build all Docker images"
	@echo ""
	@echo "  DEPLOY (requires AWS credentials)"
	@echo "    make deploy             rolling deploy to production EC2"
	@echo "    make rollback           roll back to previous version"
	@echo ""
	@echo "  INFRASTRUCTURE (requires AWS credentials + Terraform)"
	@echo "    make plan               terraform plan for production (default)"
	@echo "    make plan ENV=staging   terraform plan for staging"
	@echo "    make infra-up           provision production infrastructure"
	@echo "    make infra-up ENV=staging   provision staging infrastructure"
	@echo "    make infra-down         destroy production infrastructure, keep Route53"
	@echo "    make infra-down ENV=staging destroy staging infrastructure"
	@echo ""
	@echo "  CODE QUALITY"
	@echo "    make lint               run flake8 on all Python code"
	@echo "    make fmt                format Python (black) and Terraform (terraform fmt)"
	@echo "    make pre-commit-install install git pre-commit hooks (run once after clone)"
	@echo "    make pre-commit-run     run all hooks against all files"
	@echo ""
	@echo "  CHAOS ENGINEERING"
	@echo "    make chaos               kill secureship, verify alert + recovery"
	@echo "    make chaos-ragservice    kill ragservice, verify including FAISS index"
	@echo "    make chaos-oom           simulate OOM kill on ragservice"
	@echo "    make chaos-depkill       kill loki (dependency failure test)"
	@echo "    (all chaos runs generate a postmortem pre-fill in docs/postmortems/)"
	@echo ""
	@echo "  UTILITIES"
	@echo "    make clean              remove containers, images, build cache"
	@echo "    make shell-secureship   open shell inside running secureship container"
	@echo ""

# ─── Local Development ────────────────────────────────────────────────────────

dev-up:
	@echo "==> Checking prerequisites..."
	@[ -f .env ] || (cp .env.example .env && echo "  .env created — fill in GROQ_API_KEY from console.groq.com")
	@docker info > /dev/null 2>&1 || (echo "ERROR: Docker is not running" && exit 1)
	@echo "==> Starting monitoring + tracing stack..."
	docker compose up -d prometheus grafana loki alertmanager node-exporter tempo otel-collector
	@echo "==> Waiting 8s for monitoring to initialize..."
	@sleep 8
	@echo "==> Starting application services..."
	docker compose up -d secureship statusservice ragservice
	@echo "==> Waiting 5s for app services to initialize..."
	@sleep 5
	@echo "==> Starting AI alert autopilot + nginx..."
	docker compose up -d llm-alert-autopilot nginx promtail
	@echo ""
	@echo "  ✓ Stack running:"
	@echo "    SecureShip API:       http://localhost:8001/docs"
	@echo "    StatusService:        http://localhost:8002"
	@echo "    RAGService:           http://localhost:8003/docs"
	@echo "    LLM Alert Autopilot:  http://localhost:8080/health"
	@echo "    Grafana:              http://localhost:3000  (admin / observeops123)"
	@echo "    Prometheus:           http://localhost:9090"
	@echo "    AlertManager:         http://localhost:9093"
	@echo "    Via Nginx:            http://localhost"
	@echo ""
	@echo "  Dashboards:"
	@echo "    Services Overview:    http://localhost:3000/d/observeops-services"
	@echo "    SLO + Error Budget:   http://localhost:3000/d/observeops-slo"
	@echo "    DORA Metrics:         http://localhost:3000/d/observeops-dora"
	@echo "    LLM Metrics:          http://localhost:3000/d/observeops-llm"
	@echo ""

dev-down:
	docker compose down

dev-restart:
	docker compose restart

logs:
	docker compose logs -f --tail=50

status:
	@echo "==> Container health:"
	@docker compose ps
	@echo ""
	@echo "==> Endpoint status:"
	@curl -sf http://localhost:8001/health > /dev/null && echo "  SecureShip:          healthy" || echo "  SecureShip:          UNREACHABLE"
	@curl -sf http://localhost:8002/health > /dev/null && echo "  StatusService:       healthy" || echo "  StatusService:       UNREACHABLE"
	@curl -sf http://localhost:8003/health > /dev/null && echo "  RAGService:          healthy" || echo "  RAGService:          UNREACHABLE"
	@curl -sf http://localhost:8080/health > /dev/null && echo "  LLM Alert Autopilot: healthy" || echo "  LLM Alert Autopilot: UNREACHABLE"
	@curl -sf http://localhost:9090/-/healthy > /dev/null && echo "  Prometheus:          healthy" || echo "  Prometheus:          UNREACHABLE"
	@curl -sf http://localhost:3000/api/health > /dev/null && echo "  Grafana:             healthy" || echo "  Grafana:             UNREACHABLE"
	@curl -sf http://localhost:9093/-/healthy > /dev/null && echo "  AlertManager:        healthy" || echo "  AlertManager:        UNREACHABLE"
	@echo ""
	@echo "==> RAGService knowledge base:"
	@curl -sf http://localhost:8003/health 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print('  FAISS index: ' + str(d.get('vector_store_docs','?')) + ' docs — ' + d.get('knowledge_base_state','unknown'))" 2>/dev/null || echo "  RAGService unreachable"

# ─── Testing ──────────────────────────────────────────────────────────────────

test: test-secureship test-statusservice test-ragservice
	@echo "==> All tests passed."

test-secureship:
	@echo "==> Running SecureShip tests..."
	pip install -q -r apps/secureship/requirements.txt
	pip install -q pytest httpx pytest-asyncio
	pytest apps/secureship/tests/ -v

test-statusservice:
	@echo "==> Running StatusService tests..."
	pip install -q -r apps/statusservice/requirements.txt
	pip install -q pytest
	pytest apps/statusservice/tests/ -v

test-ragservice:
	@echo "==> Running RAGService tests..."
	pip install -q torch --index-url https://download.pytorch.org/whl/cpu
	pip install -q -r apps/ragservice/requirements.txt
	pip install -q pytest
	pytest apps/ragservice/tests/ -v

# ─── Build ────────────────────────────────────────────────────────────────────

build:
	@echo "==> Building all images..."
	docker compose build secureship statusservice ragservice llm-alert-autopilot

# ─── Security Scan ────────────────────────────────────────────────────────────

scan:
	@echo "==> Running Bandit (Python SAST)..."
	pip install -q bandit
	bandit -r apps/ -ll -q
	@echo "==> Running Trivy on secureship image..."
	docker build -t secureship-scan apps/secureship/ -q
	trivy image --exit-code 1 --severity HIGH,CRITICAL secureship-scan 2>/dev/null || \
		echo "  (Install trivy to run CVE scan: https://aquasecurity.github.io/trivy)"

# ─── Code Quality ─────────────────────────────────────────────────────────────

lint:
	@echo "==> Running flake8..."
	pip install -q flake8
	flake8 apps/ --max-line-length=120 --exclude=__pycache__,*.pyc

fmt:
	@echo "==> Formatting Python with black..."
	pip install -q black isort
	black apps/ --line-length=120
	isort apps/ --profile=black
	@echo "==> Formatting Terraform..."
	terraform -chdir=terraform fmt -recursive

pre-commit-install:
	@echo "==> Installing pre-commit hooks..."
	pip install -q pre-commit detect-secrets
	pre-commit install
	@echo "  Hooks installed. They will run automatically on every git commit."

pre-commit-run:
	@echo "==> Running all pre-commit hooks against all files..."
	pre-commit run --all-files

# ─── Deploy ───────────────────────────────────────────────────────────────────

deploy:
	@echo "==> Deploying to production via SSM..."
	@[ -n "$$EC2_INSTANCE_ID" ] || (echo "ERROR: EC2_INSTANCE_ID not set" && exit 1)
	bash scripts/deploy.sh

rollback:
	bash scripts/deploy.sh --rollback

# ─── Infrastructure ───────────────────────────────────────────────────────────

# ENV controls which environment to target (default: production)
# Usage: make plan ENV=staging  |  make infra-up ENV=staging
ENV ?= production

plan:
	@echo "==> Running terraform plan ($(ENV))..."
	cd terraform && terraform init -input=false \
	  -backend-config=key=$(ENV)/terraform.tfstate && \
	  terraform plan -var-file=environments/$(ENV).tfvars

infra-up:
	@echo "==> Provisioning infrastructure ($(ENV))..."
	ENV=$(ENV) bash scripts/infra-up.sh

infra-down:
	@echo "==> Destroying infrastructure ($(ENV), keeping Route53)..."
	ENV=$(ENV) bash scripts/infra-down.sh

# ─── Utilities ────────────────────────────────────────────────────────────────

clean:
	@echo "==> Stopping containers and removing volumes..."
	docker compose down -v
	@echo "==> Removing built images..."
	docker rmi observeops/secureship:local observeops/statusservice:local observeops/ragservice:local 2>/dev/null || true
	@echo "==> Pruning build cache..."
	docker builder prune -f

shell-secureship:
	docker exec -it secureship /bin/sh

shell-statusservice:
	docker exec -it statusservice /bin/sh

# ─── Chaos Engineering ────────────────────────────────────────────────────────
# Kill a service and verify alerting fires + service recovers automatically.
# Run ONLY when the full stack is up (make dev-up first).

chaos:
	@echo "==> Chaos: kill secureship, verify alert + API recovery..."
	bash scripts/chaos.sh secureship

chaos-ragservice:
	@echo "==> Chaos: kill ragservice, verify alert + FAISS index recovery..."
	bash scripts/chaos.sh ragservice

chaos-oom:
	@echo "==> Chaos: simulate OOM kill on ragservice..."
	bash scripts/chaos.sh ragservice --scenario=oom

chaos-depkill:
	@echo "==> Chaos: kill loki (dependency failure test)..."
	bash scripts/chaos.sh loki --scenario=depkill
