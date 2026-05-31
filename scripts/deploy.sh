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
ROLLBACK_FILE="/opt/observeops/.previous-version"
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

    log_info "Rollback complete."
    sleep 10
    if curl -sf http://localhost:8001/health > /dev/null 2>&1; then
        log_info "Rollback verified — SecureShip is healthy ✓"
    else
        log_error "Rollback verification failed. Manual intervention required."
    fi
    exit 0
fi

# ─── ECR Login ────────────────────────────────────────────────────────────────
# ECR is AWS's private Docker registry.
# We need to authenticate before pulling private images.
# The EC2 instance uses its IAM role for authentication (no credentials needed).
if [ -n "$ECR_REGISTRY" ]; then
    log_info "Logging into ECR..."
    # ECR_REGISTRY may include a namespace path (e.g. 123.dkr.ecr.region.amazonaws.com/observeops)
    # docker login needs only the registry hostname
    REGISTRY_HOST=$(echo "$ECR_REGISTRY" | cut -d'/' -f1)
    aws ecr get-login-password --region "$AWS_REGION" | \
        docker login --username AWS --password-stdin "$REGISTRY_HOST"
fi

# ─── Pull Latest Images ───────────────────────────────────────────────────────
if [ "$1" != "--local" ] && [ -n "$ECR_REGISTRY" ]; then
    log_info "Pulling latest images from ECR..."
    docker compose -f "$APP_DIR/docker-compose.yml" pull secureship statusservice ragservice
else
    log_info "Building images locally..."
    docker compose -f "$APP_DIR/docker-compose.yml" build secureship statusservice ragservice
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

log_info "Deploying RAGService..."
docker compose -f "$APP_DIR/docker-compose.yml" up -d --no-deps ragservice

log_info "Waiting for RAGService to be healthy..."
for i in $(seq 1 12); do
    if curl -sf http://localhost:8003/health > /dev/null 2>&1; then
        log_info "RAGService is healthy ✓"
        break
    fi
    log_warning "Health check failed ($i/12), waiting..."
    sleep 5
done

log_info "Ingesting runbooks into RAGService vector store..."
INGESTED=0
for f in "$APP_DIR/docs/runbooks"/*.md; do
    [ -f "$f" ] || continue
    content=$(cat "$f")
    fname=$(basename "$f")
    result=$(echo "$content" | python3 -c "
import sys, json, urllib.request
content = sys.stdin.read()
data = json.dumps({'texts': [content], 'metadatas': [{'source': '${fname}', 'type': 'runbook'}]}).encode()
req = urllib.request.Request('http://localhost:8003/ingest', data=data, headers={'Content-Type': 'application/json'})
resp = urllib.request.urlopen(req, timeout=10)
print(json.loads(resp.read()).get('chunks_created', 0))
" 2>/dev/null || echo "0")
    INGESTED=$((INGESTED + result))
done
log_info "Ingested ${INGESTED} chunks from runbooks into RAGService ✓"

log_info "Injecting obs server IP into nginx config..."
OBS_IP=$(aws ssm get-parameter \
    --name "/observeops/production/obs_server_ip" \
    --region "$AWS_REGION" \
    --query "Parameter.Value" \
    --output text 2>/dev/null || echo "")

git -C "$APP_DIR" checkout HEAD -- nginx/nginx.conf

if [ -n "$OBS_IP" ]; then
    sed -i "s|__OBS_SERVER_IP__|${OBS_IP}|g" "$APP_DIR/nginx/nginx.conf"
    log_info "Obs server IP injected: ${OBS_IP} ✓"
else
    log_warning "Obs server IP not found in SSM — Grafana/Prometheus proxy will not work"
fi

log_info "Injecting Lambda Function URL into AlertManager config..."
LAMBDA_URL=$(aws ssm get-parameter \
    --name "/observeops/production/lambda_incident_url" \
    --region "$AWS_REGION" \
    --query "Parameter.Value" \
    --output text 2>/dev/null || echo "")

# Always regenerate from the git-tracked template so the placeholder is present.
# Using sed -i without first restoring from git would leave the old URL on the
# second and subsequent deploys (the placeholder was already replaced).
git -C "$APP_DIR" checkout HEAD -- monitoring/alertmanager/alertmanager.yml

if [ -n "$LAMBDA_URL" ]; then
    sed -i "s|__LAMBDA_FUNCTION_URL__|${LAMBDA_URL}|g" \
        "$APP_DIR/monitoring/alertmanager/alertmanager.yml"
    log_info "Lambda URL injected ✓"
else
    log_warning "Lambda Function URL not found in SSM — alertmanager will use placeholder URL"
fi

log_info "Injecting Slack webhook URLs into AlertManager config..."
SLACK_CRITICAL=$(aws ssm get-parameter \
    --name "/observeops/production/slack_webhook_critical" \
    --region "$AWS_REGION" \
    --with-decryption \
    --query "Parameter.Value" \
    --output text 2>/dev/null || echo "")

SLACK_WARNINGS=$(aws ssm get-parameter \
    --name "/observeops/production/slack_webhook_warnings" \
    --region "$AWS_REGION" \
    --with-decryption \
    --query "Parameter.Value" \
    --output text 2>/dev/null || echo "")

if [ -n "$SLACK_CRITICAL" ]; then
    sed -i "s|__SLACK_WEBHOOK_CRITICAL__|${SLACK_CRITICAL}|g" \
        "$APP_DIR/monitoring/alertmanager/alertmanager.yml"
    log_info "Slack critical webhook injected ✓"
else
    log_warning "Slack critical webhook not in SSM — #alerts-critical will not receive messages"
fi

if [ -n "$SLACK_WARNINGS" ]; then
    sed -i "s|__SLACK_WEBHOOK_WARNINGS__|${SLACK_WARNINGS}|g" \
        "$APP_DIR/monitoring/alertmanager/alertmanager.yml"
    log_info "Slack warnings webhook injected ✓"
else
    log_warning "Slack warnings webhook not in SSM — #alerts-warnings will not receive messages"
fi

log_info "Starting app-server-only monitoring services..."
# Prometheus, Grafana, Loki, AlertManager run on the OBS SERVER — not here.
# The app server only runs: OTel Collector (receives traces, forwards to Tempo on obs server)
# and LLM Alert Autopilot (receives AlertManager webhooks, calls Groq, posts to Slack).
docker compose -f "$APP_DIR/docker-compose.yml" up -d otel-collector llm-alert-autopilot

# nginx resolves upstream hostnames at startup — start it after app containers
# are registered in Docker DNS to prevent "host not found" crash loop.
sleep 3
log_info "Starting nginx..."
docker compose -f "$APP_DIR/docker-compose.yml" up -d nginx

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
check_endpoint "http://localhost:8003/health"     "RAGService"
check_endpoint "http://localhost:8080/health"     "LLM Alert Autopilot"

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
echo "App Server Services:"
echo "  SecureShip API:      http://localhost:8001"
echo "  StatusService:       http://localhost:8002"
echo "  RAGService:          http://localhost:8003"
echo "  LLM Alert Autopilot: http://localhost:8080"
echo ""
echo "Monitoring (on obs server — access via secureship.click):"
echo "  Grafana:    https://secureship.click/grafana/"
echo "  Prometheus: https://secureship.click/prometheus/"
echo ""

# Log deployment event (useful for correlating incidents with deployments)
mkdir -p /var/log/observeops
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) DEPLOY SUCCESS env=$DEPLOY_ENV" >> /var/log/observeops/deployments.log
