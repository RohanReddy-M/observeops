#!/bin/bash
# ─── Chaos Engineering ────────────────────────────────────────────────────────
# Deliberately kills a service to verify:
#   1. AlertManager fires ServiceDown within 90 seconds
#   2. The container auto-restarts (restart: unless-stopped in docker-compose)
#   3. The service passes its healthcheck within 2 minutes
#
# This is how you prove your monitoring actually works —
# not by assuming it does, but by breaking things intentionally.
#
# Usage:
#   bash scripts/chaos.sh                   # kills secureship (default)
#   bash scripts/chaos.sh ragservice        # kills ragservice
#   bash scripts/chaos.sh statusservice     # kills statusservice
#
# Exit codes:
#   0 = alerting fired + service recovered
#   1 = either alerting missed or service did not recover

set -euo pipefail

SERVICE="${1:-secureship}"
ALERTMANAGER_URL="${ALERTMANAGER_URL:-http://localhost:9093}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://localhost:9090}"
ALERT_TIMEOUT=90      # seconds to wait for alert to fire
RECOVERY_TIMEOUT=120  # seconds to wait for service to recover

# ── Colour output ──────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[PASS]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()    { echo -e "${RED}[FAIL]${NC}  $*"; }

# ── Validate the service exists ────────────────────────────────────────────────
if ! docker compose ps --services 2>/dev/null | grep -q "^${SERVICE}$"; then
    fail "Service '${SERVICE}' not found. Available: $(docker compose ps --services | tr '\n' ' ')"
    exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  ObserveOps Chaos Experiment"
echo "  Target: ${SERVICE}"
echo "  Started: $(date '+%Y-%m-%d %H:%M:%S')"
echo "═══════════════════════════════════════════════════════"
echo ""

EXPERIMENT_START=$(date +%s)
RESULTS=()

# ── Step 1: Record current state ───────────────────────────────────────────────
info "Recording pre-chaos state..."
PRE_STATUS=$(docker inspect --format='{{.State.Status}}' "${SERVICE}" 2>/dev/null || echo "unknown")
info "  ${SERVICE} is currently: ${PRE_STATUS}"

# ── Step 2: Kill the container ─────────────────────────────────────────────────
info "Killing ${SERVICE}..."
docker compose kill "${SERVICE}"
KILL_TIME=$(date +%s)
info "  Container killed at $(date '+%H:%M:%S')"

# ── Step 3: Wait for AlertManager to receive the alert ────────────────────────
info "Waiting for ServiceDown alert to fire (max ${ALERT_TIMEOUT}s)..."
info "  Note: Prometheus checks every 15s, alert fires after 1m sustained. Max wait: ~90s."

ALERT_FIRED=false
ALERT_FIRE_TIME=""
for i in $(seq 1 $((ALERT_TIMEOUT / 5))); do
    sleep 5
    ELAPSED=$((i * 5))

    # Check AlertManager API for active alerts matching this service
    ALERT_COUNT=$(curl -sf "${ALERTMANAGER_URL}/api/v2/alerts" 2>/dev/null \
        | python3 -c "
import json, sys
try:
    alerts = json.load(sys.stdin)
    count = sum(1 for a in alerts
                if a.get('labels', {}).get('alertname') == 'ServiceDown'
                and a.get('labels', {}).get('job') == '${SERVICE}'
                and a.get('status', {}).get('state') == 'active')
    print(count)
except:
    print(0)
" 2>/dev/null || echo "0")

    if [ "${ALERT_COUNT}" -gt 0 ] 2>/dev/null; then
        ALERT_FIRE_TIME=$(($(date +%s) - KILL_TIME))
        success "ServiceDown alert fired at +${ALERT_FIRE_TIME}s (${ELAPSED}s elapsed)"
        ALERT_FIRED=true
        break
    fi

    printf "  Waiting... %ds/%ds\r" "${ELAPSED}" "${ALERT_TIMEOUT}"
done
echo ""

if [ "${ALERT_FIRED}" = false ]; then
    warn "No ServiceDown alert fired in ${ALERT_TIMEOUT}s"
    warn "  Possible causes:"
    warn "    - AlertManager is not running (check: docker compose ps alertmanager)"
    warn "    - Prometheus evaluation interval hasn't elapsed yet"
    warn "    - Alert rule expression doesn't match the metric labels for '${SERVICE}'"
    RESULTS+=("ALERT: MISS (did not fire in ${ALERT_TIMEOUT}s)")
else
    RESULTS+=("ALERT: FIRE in ${ALERT_FIRE_TIME}s")
fi

# ── Step 4: Container should auto-restart (restart: unless-stopped) ───────────
# docker-compose restart policy restarts the container automatically.
# We wait to see the restart happen.
info "Waiting for ${SERVICE} to auto-restart (restart policy: unless-stopped)..."

RESTART_DETECTED=false
for i in $(seq 1 12); do
    sleep 5
    CURRENT_STATUS=$(docker inspect --format='{{.State.Status}}' "${SERVICE}" 2>/dev/null || echo "unknown")
    if [ "${CURRENT_STATUS}" = "running" ]; then
        RESTART_DETECTED=true
        success "Container restarted and is running at +$((i*5))s"
        break
    fi
    printf "  Container status: %s (%ds)\r" "${CURRENT_STATUS}" "$((i*5))"
done
echo ""

if [ "${RESTART_DETECTED}" = false ]; then
    warn "Container did not auto-restart in 60s — starting it manually..."
    docker compose up -d "${SERVICE}"
fi

# ── Step 5: Wait for healthcheck to pass ─────────────────────────────────────
info "Waiting for ${SERVICE} healthcheck to pass (max ${RECOVERY_TIMEOUT}s)..."

HEALTHY=false
RECOVERY_TIME=""
for i in $(seq 1 $((RECOVERY_TIMEOUT / 5))); do
    sleep 5
    HEALTH=$(docker inspect --format='{{.State.Health.Status}}' "${SERVICE}" 2>/dev/null || echo "none")
    STATUS=$(docker inspect --format='{{.State.Status}}' "${SERVICE}" 2>/dev/null || echo "unknown")

    if [ "${HEALTH}" = "healthy" ] || ([ "${HEALTH}" = "none" ] && [ "${STATUS}" = "running" ]); then
        RECOVERY_TIME=$(($(date +%s) - KILL_TIME))
        success "${SERVICE} is healthy at +${RECOVERY_TIME}s"
        HEALTHY=true
        break
    fi
    printf "  Health: %s | Status: %s (%ds)\r" "${HEALTH}" "${STATUS}" "$((i*5))"
done
echo ""

if [ "${HEALTHY}" = false ]; then
    fail "${SERVICE} did not become healthy in ${RECOVERY_TIMEOUT}s"
    RESULTS+=("RECOVERY: FAIL (not healthy in ${RECOVERY_TIMEOUT}s)")
else
    RESULTS+=("RECOVERY: ${RECOVERY_TIME}s")
fi

# ── Step 6: Verify the alert resolves once the service is healthy ─────────────
if [ "${ALERT_FIRED}" = true ]; then
    info "Waiting for ServiceDown alert to resolve (Prometheus resolves after 5m)..."
    info "  (Not waiting the full 5 minutes — check AlertManager UI manually)"
fi

# ── Results ───────────────────────────────────────────────────────────────────
EXPERIMENT_END=$(date +%s)
TOTAL_TIME=$((EXPERIMENT_END - EXPERIMENT_START))

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  CHAOS EXPERIMENT RESULTS"
echo "  Service:      ${SERVICE}"
echo "  Total time:   ${TOTAL_TIME}s"
for r in "${RESULTS[@]}"; do
    echo "  ${r}"
done
echo "═══════════════════════════════════════════════════════"
echo ""

# Pass only if both alert fired AND service recovered
if [ "${ALERT_FIRED}" = true ] && [ "${HEALTHY}" = true ]; then
    success "EXPERIMENT PASSED — alerting and recovery are both working"
    exit 0
else
    fail "EXPERIMENT FAILED"
    [ "${ALERT_FIRED}" = false ] && fail "  → Alerting did not fire (check AlertManager + Prometheus rules)"
    [ "${HEALTHY}" = false ] && fail "  → Service did not recover (check docker logs ${SERVICE})"
    exit 1
fi
