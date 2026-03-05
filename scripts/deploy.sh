#!/bin/bash
# ─── ObserveOps Deploy Script ─────────────────────────────────────────────────
# This script deploys the latest version of the platform.
# Called by:
# 1. CI/CD pipeline after building new images
# 2. Manually when you want to redeploy
#
# Usage:
#   ./deploy.sh                    # Deploy using images from ECR
#   ./deploy.sh --local            # Build and deploy locally (no ECR)
#   ./deploy.sh --rollback         # Roll back to previous version

set -e

# ─── Configuration ────────────────────────────────────────────────────────────
# These are set as environment variables in production
# Locally you can set them before running the script
APP_DIR="${APP_DIR:-/opt/observeops}"
ECR_REGISTRY="${ECR_REGISTRY:-}"        # e.g. 123456789.dkr.ecr.ap-south-1.amazonaws.com
AWS_REGION="${AWS_REGION:-ap-south-1}"
DEPLOY_ENV="${DEPLOY_ENV:-production}"

# Colors for output (makes it easier to read)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# ─── Pre-Deploy Checks ────────────────────────────────────────────────────────
echo "═══════════════════════════════════════════"
echo "  ObserveOps Deploy - $(date)"
echo "  Environment: $DEPLOY_ENV"
echo "═══════════════════════════════════════════"

# Check Docker is running
if ! docker info >/dev/null 2>&1; then
    log_error "Docker is not running. Start it: sudo systemctl start docker"
    exit 1
fi

# ─── Save Current Version for Rollback ───────────────────────────────────────
# Before deploying, save which image is currently running
# If the new deployment fails, we use this to roll back
ROLLBACK_FILE="/tmp/observeops-previous-version"
if docker ps --format '{{.Image}}' | grep -q secureship; then
    PREVIOUS_IMAGE=$(docker ps --format '{{.Image}}' | grep secureship)
    echo "$PREVIOUS_IMAGE" > "$ROLLBACK_FILE"
    log_info "Saved rollback version: $PREVIOUS_IMAGE"
fi

# ─── Handle Rollback ─────────────────────────────────────────────────────────
if [ "$1" == "--rollback" ]; then
    if [ ! -f "$ROLLBACK_FILE" ]; then
        log_error "No rollback version found. Cannot roll back."
        exit 1
    fi
    PREVIOUS_IMAGE=$(cat "$ROLLBACK_FILE")
    log_warning "ROLLING BACK to: $PREVIOUS_IMAGE"
    
    # Update docker-compose to use the previous image
    export SECURESHIP_IMAGE="$PREVIOUS_IMAGE"
    docker compose -f "$APP_DIR/docker-compose.yml" up -d secureship statusservice
    
    log_info "Rollback complete. Verifying..."
    sleep 10
    check_health
    exit 0
fi

# ─── ECR Login ────────────────────────────────────────────────────────────────
# ECR is AWS's private Docker registry.
# We need to authenticate before pulling private images.
# The EC2 instance uses its IAM role for authentication (no credentials needed).
if [ -n "$ECR_REGISTRY" ]; then
    log_info "Logging into ECR..."
    aws ecr get-login-password --region "$AWS_REGION" | \
        docker login --username AWS --password-stdin "$ECR_REGISTRY"
fi

# ─── Pull Latest Images ───────────────────────────────────────────────────────
if [ "$1" != "--local" ] && [ -n "$ECR_REGISTRY" ]; then
    log_info "Pulling latest images from ECR..."
    docker compose -f "$APP_DIR/docker-compose.yml" pull secureship statusservice
else
    log_info "Building images locally..."
    docker compose -f "$APP_DIR/docker-compose.yml" build secureship statusservice
fi

# ─── Deploy ───────────────────────────────────────────────────────────────────
log_info "Deploying services..."

# Rolling deployment: update one service at a time
# This keeps the platform partially available during deployment
# (true zero-downtime requires multiple instances, but this minimizes impact)

log_info "Deploying SecureShip..."
docker compose -f "$APP_DIR/docker-compose.yml" up -d --no-deps secureship

# Wait for SecureShip to be healthy before deploying StatusService
log_info "Waiting for SecureShip to be healthy..."
RETRIES=0
MAX_RETRIES=12  # 12 * 5 seconds = 60 second timeout

while [ $RETRIES -lt $MAX_RETRIES ]; do
    if curl -sf http://localhost:8001/health > /dev/null 2>&1; then
        log_info "SecureShip is healthy ✓"
        break
    fi
    RETRIES=$((RETRIES + 1))
    log_warning "Health check failed ($RETRIES/$MAX_RETRIES), waiting..."
    sleep 5
done

if [ $RETRIES -eq $MAX_RETRIES ]; then
    log_error "SecureShip failed to become healthy after 60 seconds"
    log_warning "Initiating automatic rollback..."
    
    if [ -f "$ROLLBACK_FILE" ]; then
        "$0" --rollback
    else
        log_error "No rollback version available. Manual intervention required."
    fi
    exit 1
fi

log_info "Deploying StatusService..."
docker compose -f "$APP_DIR/docker-compose.yml" up -d --no-deps statusservice

# Deploy remaining infrastructure services (nginx, monitoring)
log_info "Updating nginx and monitoring stack..."
docker compose -f "$APP_DIR/docker-compose.yml" up -d nginx prometheus grafana loki promtail alertmanager node-exporter

# ─── Post-Deploy Smoke Tests ──────────────────────────────────────────────────
# Smoke tests verify the deployment didn't break basic functionality.
# "Smoke test" name comes from electronics: power it on, does it smoke? No? Good.
log_info "Running smoke tests..."
sleep 5

SMOKE_TESTS_PASSED=true

check_endpoint() {
    local url=$1
    local name=$2
    if curl -sf "$url" > /dev/null 2>&1; then
        log_info "✓ $name is responding"
    else
        log_error "✗ $name is NOT responding at $url"
        SMOKE_TESTS_PASSED=false
    fi
}

check_endpoint "http://localhost/health"          "SecureShip (via Nginx)"
check_endpoint "http://localhost:8001/health"     "SecureShip (direct)"
check_endpoint "http://localhost:8002/health"     "StatusService"
check_endpoint "http://localhost:9090/-/healthy"  "Prometheus"
check_endpoint "http://localhost:3000/api/health" "Grafana"
check_endpoint "http://localhost:3100/ready"      "Loki"

if [ "$SMOKE_TESTS_PASSED" = false ]; then
    log_error "Smoke tests failed! Initiating rollback..."
    "$0" --rollback
    exit 1
fi

# ─── Deployment Complete ──────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════"
log_info "Deployment successful! ✓"
echo "═══════════════════════════════════════════"
echo ""
echo "Services:"
echo "  SecureShip API:  http://localhost:8001"
echo "  StatusService:   http://localhost:8002"  
echo "  Grafana:         http://localhost:3000  (admin/observeops123)"
echo "  Prometheus:      http://localhost:9090"
echo ""

# Log deployment event (useful for correlating incidents with deployments)
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) DEPLOY SUCCESS env=$DEPLOY_ENV" >> /var/log/observeops/deployments.log
