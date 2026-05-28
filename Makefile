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
	@echo "    make plan               terraform plan (shows what will change)"
	@echo "    make infra-up           provision all AWS infrastructure"
	@echo "    make infra-down         destroy infrastructure, keep Route53"
	@echo ""
	@echo "  CODE QUALITY"
	@echo "    make lint               run flake8 on all Python code"
	@echo "    make fmt                format Python (black) and Terraform (terraform fmt)"
	@echo ""
	@echo "  UTILITIES"
	@echo "    make clean              remove containers, images, build cache"
	@echo "    make shell-secureship   open shell inside running secureship container"
	@echo ""

# ─── Local Development ────────────────────────────────────────────────────────

dev-up:
	@echo "==> Checking prerequisites..."
	@[ -f .env ] || (cp .env.example .env && echo "  .env created from .env.example — add your GROQ_API_KEY")
	@docker info > /dev/null 2>&1 || (echo "ERROR: Docker is not running" && exit 1)
	@echo "==> Starting monitoring stack first (Prometheus, Grafana, Loki)..."
	docker compose up -d prometheus grafana loki alertmanager node-exporter
	@echo "==> Waiting 5s for monitoring to initialize..."
	@sleep 5
	@echo "==> Starting application services..."
	docker compose up -d secureship statusservice ragservice
	@echo "==> Waiting for services to be healthy..."
	@sleep 5
	@echo "==> Starting nginx (after all upstreams are ready)..."
	docker compose up -d nginx promtail
	@echo ""
	@echo "  Services running:"
	@echo "    SecureShip API:  http://localhost:8001/docs"
	@echo "    StatusService:   http://localhost:8002"
	@echo "    RAGService:      http://localhost:8003/docs"
	@echo "    Grafana:         http://localhost:3000  (admin / observeops123)"
	@echo "    Prometheus:      http://localhost:9090"
	@echo "    AlertManager:    http://localhost:9093"
	@echo "    Via Nginx:       http://localhost"
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
	@curl -sf http://localhost:8001/health > /dev/null && echo "  SecureShip:   healthy" || echo "  SecureShip:   UNREACHABLE"
	@curl -sf http://localhost:8002/health > /dev/null && echo "  StatusService:healthy" || echo "  StatusService:UNREACHABLE"
	@curl -sf http://localhost:8003/health > /dev/null && echo "  RAGService:   healthy" || echo "  RAGService:   UNREACHABLE"
	@curl -sf http://localhost:9090/-/healthy > /dev/null && echo "  Prometheus:   healthy" || echo "  Prometheus:   UNREACHABLE"
	@curl -sf http://localhost:3000/api/health > /dev/null && echo "  Grafana:      healthy" || echo "  Grafana:      UNREACHABLE"

# ─── Testing ──────────────────────────────────────────────────────────────────

test: test-secureship test-ragservice
	@echo "==> All tests passed."

test-secureship:
	@echo "==> Running SecureShip tests..."
	pip install -q -r apps/secureship/requirements.txt
	pip install -q pytest httpx pytest-asyncio
	pytest apps/secureship/tests/ -v

test-ragservice:
	@echo "==> Running RAGService tests..."
	pip install -q torch --index-url https://download.pytorch.org/whl/cpu
	pip install -q -r apps/ragservice/requirements.txt
	pip install -q pytest
	pytest apps/ragservice/tests/ -v

# ─── Build ────────────────────────────────────────────────────────────────────

build:
	@echo "==> Building all images..."
	docker compose build secureship statusservice ragservice

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

# ─── Deploy ───────────────────────────────────────────────────────────────────

deploy:
	@echo "==> Deploying to production via SSM..."
	@[ -n "$$EC2_INSTANCE_ID" ] || (echo "ERROR: EC2_INSTANCE_ID not set" && exit 1)
	bash scripts/deploy.sh

rollback:
	bash scripts/deploy.sh --rollback

# ─── Infrastructure ───────────────────────────────────────────────────────────

plan:
	@echo "==> Running terraform plan..."
	cd terraform && terraform init -input=false && terraform plan -var-file=terraform.tfvars

infra-up:
	@echo "==> Provisioning infrastructure..."
	bash scripts/infra-up.sh

infra-down:
	@echo "==> Destroying infrastructure (keeping Route53)..."
	bash scripts/infra-down.sh

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
