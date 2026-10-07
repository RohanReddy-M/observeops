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

# -o pipefail: without it, `aws ecr get-login-password | docker login ...` (below)
# only reports docker login's exit code — a failed `aws` call with a working
# `docker login` on empty stdin could slip through undetected. Not adding -u
# (nounset) here: this script leans on bare $1 checks throughout, and retrofitting
# that safely means auditing every reference, not a one-line change.
set -eo pipefail

# The script rolls itself back by running itself with --rollback. Name the file by an
# absolute path and run it through bash. "$0" was not enough: started as
# `bash scripts/deploy.sh`, it is the relative path scripts/deploy.sh, and the file was
# not executable in git, so the call failed with 'Permission denied' (126) after the
# script had already said "Initiating automatic rollback". The broken release stayed up.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

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

# Read one parameter from SSM. Empty string when it does not exist.
ssm_get() {   # ssm_get <name> [--with-decryption]
    aws ssm get-parameter --name "/observeops/production/$1" --region "$AWS_REGION" \
        ${2:+$2} --query "Parameter.Value" --output text 2>/dev/null || echo ""
}

# Set KEY=VALUE in .env: replace the line if present, append otherwise.
set_env() {   # set_env KEY VALUE
    touch "$APP_DIR/.env"
    sed -i "/^$1=/d" "$APP_DIR/.env" 2>/dev/null || true
    printf '%s=%s\n' "$1" "$2" >> "$APP_DIR/.env"
}

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

# ─── Pre-Deploy Validation ────────────────────────────────────────────────────
# Catch configuration problems before touching running containers.
# Fail fast here rather than fail mid-deploy and leave the stack in a broken state.

if [ -z "$ECR_REGISTRY" ] && [ "$1" != "--local" ] && [ "$1" != "--rollback" ]; then
    log_error "ECR_REGISTRY not set. Either set it or pass --local to build from source."
    exit 1
fi

# Verify critical secrets exist in SSM (warn only — don't block deploy)
for secret in "groq_api_key" "secureship_api_key" "obs_server_ip"; do
    if ! aws ssm get-parameter --name "/observeops/production/$secret" \
        --region "$AWS_REGION" >/dev/null 2>&1; then
        log_warning "SSM secret '$secret' not found — some features may not work"
    fi
done

# Remove unused Docker images before checking disk space.
# 200+ CI runs each pull new images — without this the 20GB root volume fills
# in a few weeks and every subsequent deploy fails the 2GB free check.
# Not during a rollback: by then the previous image is no longer used by any
# container, so "prune unused" would delete exactly the image we are about to
# roll back to and force a re-pull in the middle of an incident.
if [ "$1" != "--rollback" ]; then
    log_info "Pruning unused Docker images..."
    # Output discarded: it lists every deleted layer, and CI can only read back
    # the first 24,000 characters of this script's output from SSM.
    docker image prune -a -f > /dev/null 2>&1 || true
fi

# Verify disk space — need at least 2GB free to pull/build images
AVAILABLE_KB=$(df /var/lib/docker 2>/dev/null | awk 'NR==2 {print $4}' || df / | awk 'NR==2 {print $4}')
if [ -n "$AVAILABLE_KB" ] && [ "$AVAILABLE_KB" -lt 2097152 ]; then
    log_error "Insufficient disk space. Need 2GB free, have $((AVAILABLE_KB / 1024))MB."
    log_error "Run: sudo docker system prune -f"
    exit 1
fi

# ─── Save Current Version for Rollback ───────────────────────────────────────
# Before deploying, save which image is currently running
# If the new deployment fails, we use this to roll back
#
# Two conditions, both of which this block used to ignore:
#
#  1. Not when we ARE the rollback. A failed deploy re-invokes this script with
#     --rollback, and this block runs before the rollback handler below. At that
#     moment the running secureship container is the new, broken one, so recording
#     "the current image" overwrote the rollback target with the very image that
#     had just failed, and the "rollback" redeployed it.
#  2. Only when the running container is healthy. An image that is up but failing
#     its health check is not a version worth returning to.
ROLLBACK_FILE="/opt/observeops/.previous-version"
if [ "$1" != "--rollback" ]; then
    CURRENT_IMAGE=$(docker inspect --format '{{.Config.Image}}' secureship 2>/dev/null || echo "")
    CURRENT_HEALTH=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' secureship 2>/dev/null || echo "none")
    if [ -n "$CURRENT_IMAGE" ] && [ "$CURRENT_HEALTH" = "healthy" ]; then
        echo "$CURRENT_IMAGE" > "$ROLLBACK_FILE"
        log_info "Saved rollback version: $CURRENT_IMAGE"
    elif [ -n "$CURRENT_IMAGE" ]; then
        log_warning "Running secureship ($CURRENT_IMAGE) is '$CURRENT_HEALTH', not healthy — keeping the existing rollback target"
    fi
fi

# ─── Handle Rollback ─────────────────────────────────────────────────────────
if [ "$1" == "--rollback" ]; then
    if [ ! -f "$ROLLBACK_FILE" ]; then
        log_error "No rollback version found. Cannot roll back."
        exit 1
    fi
    PREVIOUS_IMAGE=$(cat "$ROLLBACK_FILE")
    log_warning "ROLLING BACK to: $PREVIOUS_IMAGE"

    # docker-compose.yml resolves images from ECR_REGISTRY + IMAGE_TAG
    # (image: ${ECR_REGISTRY:-observeops}/secureship:${IMAGE_TAG:-local}) — exporting
    # the full image string alone is a no-op, compose never reads it. Split
    # PREVIOUS_IMAGE ("<registry>/secureship:<tag>") back into the two vars compose
    # actually uses, and re-invoking this same script with them set (e.g. via
    # `bash "$SELF" --rollback` from a failed health check below, or from CI on --rollback)
    # deploys the exact previous image, not whatever IMAGE_TAG happened to be
    # inherited from the failed run's environment.
    export IMAGE_TAG="${PREVIOUS_IMAGE##*:}"
    export ECR_REGISTRY="${PREVIOUS_IMAGE%/secureship:*}"
    # Record it, for the same reason a deploy does (see "Refresh .env" below): a
    # reboot must bring back the version we rolled back to, not the one that failed.
    set_env IMAGE_TAG "$IMAGE_TAG"
    set_env ECR_REGISTRY "$ECR_REGISTRY"
    # --no-deps for the same reason as the forward path below: without it compose
    # would also start the Loki it lists as a dependency, on the wrong host.
    docker compose -f "$APP_DIR/docker-compose.yml" up -d --no-deps secureship statusservice ragservice llm-alert-autopilot

    log_info "Rollback issued. Verifying..."
    for _ in $(seq 1 12); do
        if curl -sf http://localhost:8001/health > /dev/null 2>&1; then
            log_info "Rollback verified — SecureShip is healthy on $PREVIOUS_IMAGE ✓"
            exit 0
        fi
        sleep 5
    done
    # A rollback that did not restore service must not report success: the caller
    # (CI, or the failed deploy above) needs a non-zero exit to know a human is needed.
    log_error "Rollback verification failed after 60s. Manual intervention required."
    exit 2
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
    # --quiet for the same reason as the prune above: per-layer progress lines
    # would use up the output CI is able to show.
    docker compose -f "$APP_DIR/docker-compose.yml" pull --quiet secureship statusservice ragservice llm-alert-autopilot
else
    log_info "Building images locally..."
    docker compose -f "$APP_DIR/docker-compose.yml" build secureship statusservice ragservice llm-alert-autopilot
fi

# ─── Refresh .env ─────────────────────────────────────────────────────────────
# This runs BEFORE any container is started, because the containers read these
# values at start. It used to run after the services were already up, which only
# worked because nothing in .env was required for startup. SECURESHIP_API_KEY is:
# secureship refuses to start without it whenever a DynamoDB table is configured.
#
# Nothing below edits a tracked config file. nginx.conf, the OTel collector config
# and alertmanager.yml used to be rewritten in place with sed on every deploy; they
# now refer to the other host by name ("obs-server", "app-server"), and compose maps
# that name to the IP held in .env via extra_hosts.
log_info "Refreshing .env from SSM..."

GROQ_KEY=$(ssm_get groq_api_key --with-decryption)
if [ -n "$GROQ_KEY" ]; then
    set_env GROQ_API_KEY "$GROQ_KEY"
    log_info "GROQ_API_KEY refreshed ✓"
else
    log_warning "GROQ_API_KEY not found in SSM — LLM diagnosis will be disabled"
fi

SECURESHIP_KEY=$(ssm_get secureship_api_key --with-decryption)
if [ -n "$SECURESHIP_KEY" ]; then
    set_env SECURESHIP_API_KEY "$SECURESHIP_KEY"
    log_info "SECURESHIP_API_KEY refreshed ✓"
else
    log_warning "secureship_api_key not found in SSM — secureship will refuse to start if DYNAMODB_TABLE is set"
fi

# Record which images this deploy runs. docker-compose.yml resolves image names from
# ECR_REGISTRY and IMAGE_TAG; CI passes them only as environment variables for this
# one invocation. Without writing them down, any later `docker compose up` that
# does not have them in its environment — the systemd unit after a reboot, or a
# person on the box — resolves to observeops/<service>:local and silently replaces
# the deployed version with a build of whatever happens to be checked out.
if [ -n "$ECR_REGISTRY" ] && [ "$1" != "--local" ]; then
    set_env ECR_REGISTRY "$ECR_REGISTRY"
    set_env IMAGE_TAG "${IMAGE_TAG:-latest}"
fi

OBS_IP="${OBS_SERVER_IP:-$(ssm_get obs_server_ip)}"
if [ -n "$OBS_IP" ]; then
    # OBS_SERVER_IP: what "obs-server" resolves to for nginx, the OTel collector
    # and Alloy (the log shipper).
    # LOKI_URL: where llm-alert-autopilot queries logs.
    set_env OBS_SERVER_IP "$OBS_IP"
    set_env LOKI_URL "http://${OBS_IP}:3100"
    log_info "Observability server address written to .env: ${OBS_IP} ✓"
else
    log_warning "Obs server IP not found — Grafana/Prometheus proxy, traces and log shipping will not work"
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
        bash "$SELF" --rollback || { log_error "The rollback did not restore service. Manual intervention required."; exit 2; }
    else
        log_error "No rollback version available. Manual intervention required."
    fi
    exit 1
fi

log_info "Deploying StatusService..."
docker compose -f "$APP_DIR/docker-compose.yml" up -d --no-deps statusservice

log_info "Deploying RAGService..."
docker compose -f "$APP_DIR/docker-compose.yml" up -d --no-deps ragservice

# Three minutes, not one. RAGService imports PyTorch and loads an embedding model
# before it can answer. On a warm host that takes about 20 s; on the first start
# after a fresh image pull, on a 2 GB burstable instance with a cold disk cache,
# it can take well over a minute. A health timeout shorter than the slowest
# legitimate start does not catch failures, it manufactures them, and here the
# "failure" would trigger a rollback of a perfectly good deploy.
log_info "Waiting for RAGService to be healthy..."
RAG_RETRIES=0
RAG_MAX_RETRIES=36
RAG_HEALTHY=false
while [ $RAG_RETRIES -lt $RAG_MAX_RETRIES ]; do
    if curl -sf http://localhost:8003/health > /dev/null 2>&1; then
        log_info "RAGService is healthy ✓"
        RAG_HEALTHY=true
        break
    fi
    RAG_RETRIES=$((RAG_RETRIES + 1))
    log_warning "Health check failed ($RAG_RETRIES/$RAG_MAX_RETRIES), waiting..."
    sleep 5
done

# Unlike SecureShip above, a stuck RAGService used to fall through silently here
# and the deploy would carry on as if nothing were wrong — the only thing that
# eventually caught it was the much coarser smoke-test block at the end.
if [ "$RAG_HEALTHY" = false ]; then
    log_error "RAGService failed to become healthy after 180 seconds"
    log_warning "Initiating automatic rollback..."
    if [ -f "$ROLLBACK_FILE" ]; then
        bash "$SELF" --rollback || { log_error "The rollback did not restore service. Manual intervention required."; exit 2; }
    else
        log_error "No rollback version available. Manual intervention required."
    fi
    exit 1
fi

# The knowledge base is not loaded from here. RAGService builds its index from
# docs/runbooks (mounted into the container) every time it starts, so there is
# nothing to ingest. What IS checked: that it really did start from the runbooks
# and not from its built-in fallback, which would mean the mount is missing and
# every answer would come from nine stale paragraphs.
#
# This replaced an "ingest the runbooks unless the store already has documents"
# step. The store always had documents (the fallback), so that step skipped
# itself on every deploy and the runbooks were never loaded in production.
KB_STATE=$(curl -sf http://localhost:8003/health 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('knowledge_base_source', 'unknown'), d.get('vector_store_docs', 0))
except Exception:
    print('unknown 0')
" 2>/dev/null || echo "unknown 0")
KB_SOURCE="${KB_STATE%% *}"
KB_DOCS="${KB_STATE##* }"
if [ "$KB_SOURCE" = "runbooks" ] && [ "${KB_DOCS:-0}" -gt 0 ] 2>/dev/null; then
    log_info "RAGService knowledge base: ${KB_DOCS} chunks built from docs/runbooks ✓"
else
    log_error "RAGService knowledge base is '${KB_SOURCE}' with ${KB_DOCS} chunks; expected the runbooks"
    log_warning "Initiating automatic rollback..."
    if [ -f "$ROLLBACK_FILE" ]; then
        bash "$SELF" --rollback || { log_error "The rollback did not restore service. Manual intervention required."; exit 2; }
    else
        log_error "No rollback version available. Manual intervention required."
    fi
    exit 1
fi

log_info "Starting app-server-only monitoring services..."
# Prometheus, Grafana, Loki, AlertManager run on the OBS SERVER — not here.
# The app server only runs: OTel Collector (receives traces, forwards to Tempo on obs server)
# and LLM Alert Autopilot (receives AlertManager webhooks, calls Groq, posts to Slack).
# node-exporter runs here too: without it this host had no CPU, memory or disk
# metrics at all, and the disk-space alerts were watching only the obs server.
# compose recreates a container whenever its resolved config changed (including an
# extra_hosts address that came from .env), so no --force-recreate is needed.
#
# --no-deps: docker-compose.yml declares Loki as a dependency of the autopilot
# and Tempo as a dependency of the collector. That is right on one host,
# but here they live on the obs server; without the flag compose would start a
# second, unused Loki and Tempo on this 2 GB instance.
docker compose -f "$APP_DIR/docker-compose.yml" up -d --no-deps otel-collector llm-alert-autopilot alloy node-exporter

# nginx goes last. That is no longer about name resolution: nginx.conf now
# re-resolves its backends at runtime (the `resolve` parameter), so a backend that
# is recreated later, or missing at startup, does not need nginx restarted. It is
# last so that the first request it accepts lands on containers already running
# the new image.
log_info "Starting nginx..."
# --force-recreate: `git pull` replaces nginx.conf with a new inode, and a bind
# mount keeps pointing at the old one, so a plain `up -d` could leave nginx
# serving the previous config.
docker compose -f "$APP_DIR/docker-compose.yml" up -d --force-recreate nginx

# ─── Post-Deploy Smoke Tests ──────────────────────────────────────────────────
# Smoke tests verify the deployment didn't break basic functionality.
# "Smoke test" name comes from electronics: power it on, does it smoke? No? Good.
log_info "Running smoke tests..."
sleep 5

SMOKE_TESTS_PASSED=true

check_endpoint() {
    local url=$1
    local name=$2
    local waited=0
    # A container that was just recreated needs a few seconds before it answers. Poll
    # rather than make one request after a fixed sleep: that race failed a real deploy
    # on 7 Oct 2026 (the alert autopilot was still starting) and rolled back a healthy
    # release. Give up after 60 s, and say so.
    until curl -sf "$url" > /dev/null 2>&1; do
        if [ "$waited" -ge 60 ]; then
            log_error "✗ $name is NOT responding at $url after ${waited}s"
            SMOKE_TESTS_PASSED=false
            return
        fi
        sleep 2
        waited=$((waited + 2))
    done
    if [ "$waited" -gt 0 ]; then
        log_info "✓ $name is responding (after ${waited}s)"
    else
        log_info "✓ $name is responding"
    fi
}

check_endpoint "http://localhost/health"          "SecureShip (via Nginx)"
check_endpoint "http://localhost:8001/health"     "SecureShip (direct)"
check_endpoint "http://localhost:8002/health"     "StatusService"
check_endpoint "http://localhost:8003/health"     "RAGService"
check_endpoint "http://localhost:8080/health"     "LLM Alert Autopilot"

# The five checks above prove five processes answer. The next three prove the
# service works: /ready fails unless DynamoDB is reachable, the authenticated call
# exercises auth and the datastore end to end, and the unauthenticated call must be
# REFUSED — a deploy that quietly came up with auth disabled is a failed deploy.
check_endpoint "http://localhost:8001/ready"      "SecureShip readiness (datastore reachable)"

# `|| true`: under `set -eo pipefail` a grep that matches nothing fails the whole
# assignment and would end the script right here, without a word.
SMOKE_KEY=$(grep -E '^SECURESHIP_API_KEY=' "$APP_DIR/.env" 2>/dev/null | cut -d= -f2- || true)
if [ -n "$SMOKE_KEY" ]; then
    if curl -sf -H "X-API-Key: ${SMOKE_KEY}" "http://localhost:8001/api/v1/ships?limit=1" > /dev/null 2>&1; then
        log_info "✓ Authenticated API call succeeded"
    else
        log_error "✗ Authenticated API call FAILED"
        SMOKE_TESTS_PASSED=false
    fi
    UNAUTH_CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:8001/api/v1/ships?limit=1" 2>/dev/null || echo "000")
    if [ "$UNAUTH_CODE" = "401" ]; then
        log_info "✓ Unauthenticated API call correctly refused (401)"
    else
        log_error "✗ Unauthenticated API call returned ${UNAUTH_CODE}, expected 401 — auth is not enforced"
        SMOKE_TESTS_PASSED=false
    fi
else
    log_warning "No SECURESHIP_API_KEY in .env — skipping authenticated smoke tests"
fi

if [ "$SMOKE_TESTS_PASSED" = false ]; then
    log_error "Smoke tests failed! Initiating rollback..."
    bash "$SELF" --rollback || { log_error "The rollback did not restore service. Manual intervention required."; exit 2; }
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
echo "Monitoring (on the obs server, proxied by nginx):"
echo "  Grafana:    <public URL>/grafana/"
echo "  Prometheus: <public URL>/prometheus/"
echo ""

# ─── Register deployment with LLM Alert Autopilot (DORA + LLM context) ───────
# This is what makes the LLM say "this alert started 8 minutes after commit X."
# Without this, the on-call has to manually correlate alert time with git log.
DEPLOY_COMMIT="${IMAGE_TAG:-$(git -C "${APP_DIR:-/opt/observeops}" rev-parse --short HEAD 2>/dev/null || echo "unknown")}"
DEPLOY_USER="${DEPLOY_USER:-$(whoami)}"

# Neither the deploy-event endpoint nor the Grafana annotation API dedupe on their
# own — a CI retry re-running this script for the same commit would otherwise
# double-count DORA's deployment-frequency metric and leave a duplicate marker
# line on every dashboard. Guard on a local marker instead.
LAST_DEPLOY_FILE="/opt/observeops/.last-registered-deploy"
if [ -f "$LAST_DEPLOY_FILE" ] && [ "$(cat "$LAST_DEPLOY_FILE")" = "$DEPLOY_COMMIT" ]; then
    log_info "Deploy event for commit ${DEPLOY_COMMIT} already registered — skipping duplicate DORA event and annotation"
else
    curl -sf -X POST http://localhost:8080/deploy-event \
        -H "Content-Type: application/json" \
        -d "{
            \"commit\":   \"${DEPLOY_COMMIT}\",
            \"deployer\": \"${DEPLOY_USER}\",
            \"status\":   \"success\",
            \"services\": [\"secureship\", \"statusservice\", \"ragservice\"]
        }" > /dev/null 2>&1 || true  # non-fatal — monitoring shouldn't block deploy

    # ─── Grafana deployment annotation ───────────────────────────────────────
    # A vertical marker on every dashboard at the moment of the deploy, so "did
    # this start with a release?" is answered by looking. Posted from here, not
    # from GitHub Actions, because Grafana has no public address.
    # Never fatal: a missing marker must not fail a deploy. But say what happened;
    # this used to print "posted" whether or not the request had succeeded.
    GRAFANA_PASS=$(ssm_get grafana_admin_password --with-decryption)
    if [ -n "$OBS_IP" ] && [ -n "$GRAFANA_PASS" ]; then
        if curl -sf -m 10 -X POST "http://${OBS_IP}:3000/api/annotations" \
            -u "admin:${GRAFANA_PASS}" \
            -H "Content-Type: application/json" \
            -d "{\"text\":\"Deploy: ${DEPLOY_COMMIT} by ${DEPLOY_USER}\",\"tags\":[\"deployment\",\"production\"]}" \
            > /dev/null 2>&1; then
            log_info "Grafana deployment annotation posted ✓"
        else
            log_warning "Grafana deployment annotation was NOT posted (Grafana unreachable or rejected it)"
        fi
    else
        log_warning "Skipping the Grafana annotation: obs server address or Grafana password not available"
    fi

    echo "$DEPLOY_COMMIT" > "$LAST_DEPLOY_FILE"
fi

# Log deployment event locally as backup — always, even on a skipped duplicate,
# since this is a local audit trail, not a metric that gets corrupted by re-runs.
mkdir -p /var/log/observeops
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) DEPLOY SUCCESS commit=${DEPLOY_COMMIT} deployer=${DEPLOY_USER}" \
    >> /var/log/observeops/deployments.log
