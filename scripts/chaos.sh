#!/bin/bash
# ─── Chaos Engineering ────────────────────────────────────────────────────────
# Deliberately inject failures into ObserveOps to verify:
#   1. Alerting fires correctly and on time
#   2. Services recover automatically (restart policy, health checks)
#   3. End-to-end functionality works after recovery (not just "container is up")
#   4. The AI (LLM Alert Autopilot) diagnoses the failure correctly from logs
#
# PHILOSOPHY: We break things on purpose because:
#   - A junior fears production breaking. A senior knows it will break and has
#     already proven what happens when it does.
#   - "Restarting fixed it" is not a root cause. We want to find the cause,
#     not just restore the symptom.
#   - If your monitoring doesn't alert on a deliberate kill, it won't alert on
#     a real failure either.
#
# Usage:
#   bash scripts/chaos.sh                          # default: kill secureship
#   bash scripts/chaos.sh secureship               # kill scenario
#   bash scripts/chaos.sh secureship --scenario=oom    # OOM scenario
#   bash scripts/chaos.sh secureship --scenario=depkill  # kill its dependency
#
# Output: writes a postmortem pre-fill to docs/postmortems/

set -euo pipefail

SERVICE="${1:-secureship}"
SCENARIO="kill"
POSTMORTEM_DIR="docs/postmortems"
ALERTMANAGER_URL="${ALERTMANAGER_URL:-http://localhost:9093}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://localhost:9090}"
ALERT_TIMEOUT=90
RECOVERY_TIMEOUT=120

# Parse --scenario= argument
for arg in "$@"; do
    case $arg in
        --scenario=*) SCENARIO="${arg#*=}";;
    esac
done

# ── Ports by service (for end-to-end verification) ───────────────────────────
declare -A SERVICE_PORTS=(
    [secureship]=8001
    [ragservice]=8003
    [statusservice]=8002
    [llm-alert-autopilot]=8080
)
declare -A SERVICE_HEALTH_PATH=(
    [secureship]="/health"
    [ragservice]="/health"
    [statusservice]="/health"
    [llm-alert-autopilot]="/health"
)

# ── Colour output ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}    $*"; }
success() { echo -e "${GREEN}[PASS]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}    $*"; }
fail()    { echo -e "${RED}[FAIL]${NC}    $*"; }
step()    { echo -e "${CYAN}[STEP]${NC}    $*"; }

# ── Validate ─────────────────────────────────────────────────────────────────
if ! docker compose ps --services 2>/dev/null | grep -q "^${SERVICE}$"; then
    fail "Service '${SERVICE}' not found. Available:"
    docker compose ps --services | sed 's/^/  /'
    exit 1
fi

PORT="${SERVICE_PORTS[$SERVICE]:-}"
HEALTH_PATH="${SERVICE_HEALTH_PATH[$SERVICE]:-/health}"

# ── Report state ─────────────────────────────────────────────────────────────
EXPERIMENT_START=$(date +%s)
EXPERIMENT_DATE=$(date '+%Y-%m-%d_%H-%M-%S')
RESULTS_FILE="${POSTMORTEM_DIR}/${EXPERIMENT_DATE}-chaos-${SERVICE}-${SCENARIO}.md"

mkdir -p "${POSTMORTEM_DIR}"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  ObserveOps Chaos Experiment                             ║"
printf "║  Service:  %-44s ║\n" "${SERVICE}"
printf "║  Scenario: %-44s ║\n" "${SCENARIO}"
printf "║  Started:  %-44s ║\n" "$(date '+%Y-%m-%d %H:%M:%S UTC')"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ── Inject the failure ────────────────────────────────────────────────────────
step "Injecting failure (scenario: ${SCENARIO})..."

case "${SCENARIO}" in
    kill)
        # Hard kill — simulates process crash (OOM, kernel signal, crash)
        docker compose kill "${SERVICE}"
        FAILURE_DESC="Hard kill (SIGKILL) — simulates OOM kill, kernel panic, or process crash"
        ;;

    oom)
        # Simulate OOM by running a memory hog inside the container until Docker kills it
        # This is how real OOM kills happen — memory grows until the kernel intervenes
        info "Injecting OOM pressure (allocating memory until container is killed)..."
        docker exec "${SERVICE}" python3 -c "
x = []
try:
    while True:
        x.append(' ' * 10_000_000)  # allocate 10MB per iteration
except MemoryError:
    pass
# If we get here, limits stopped us before OOM kill
import sys; sys.exit(1)
" &
        sleep 5
        # Container may still be up (if memory limit stopped us) or dead (if kernel killed it)
        # Either way, let's treat it as degraded
        CURRENT=$(docker inspect --format='{{.State.Status}}' "${SERVICE}" 2>/dev/null || echo "gone")
        if [ "${CURRENT}" != "running" ]; then
            FAILURE_DESC="OOM kill — container exceeded memory limit and was killed by the kernel"
        else
            # Container survived — memory limit worked. Kill it to simulate the scenario anyway.
            docker compose kill "${SERVICE}"
            FAILURE_DESC="Simulated OOM — killed after memory pressure test (limits prevented actual OOM)"
        fi
        ;;

    depkill)
        # Kill a service's dependency to see how it degrades
        # For secureship: kill loki (logging dependency)
        # For ragservice: kill loki AND the alert depends on it being down
        DEP_SERVICE="loki"
        info "Killing dependency '${DEP_SERVICE}' to test degraded operation..."
        docker compose kill "${DEP_SERVICE}"
        FAILURE_DESC="Dependency killed: ${DEP_SERVICE} — testing graceful degradation when logging is unavailable"
        SERVICE="${DEP_SERVICE}"  # monitor the dependency
        ;;

    *)
        fail "Unknown scenario: ${SCENARIO}. Valid: kill, oom, depkill"
        exit 1
        ;;
esac

KILL_TIME=$(date +%s)
info "Failure injected at $(date '+%H:%M:%S')"

# ── Wait for alert to fire ────────────────────────────────────────────────────
step "Waiting for ServiceDown alert to fire in AlertManager (max ${ALERT_TIMEOUT}s)..."
info "  Prometheus evaluates rules every 15s, alert fires after 'for: 1m' gate"
info "  Expected: alert fires between 60-90 seconds after failure"

ALERT_FIRED=false
ALERT_FIRE_SECONDS=""

for i in $(seq 1 $((ALERT_TIMEOUT / 5))); do
    sleep 5
    ELAPSED=$((i * 5))

    ALERT_COUNT=$(curl -sf "${ALERTMANAGER_URL}/api/v2/alerts" 2>/dev/null \
        | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    count = sum(1 for a in data
                if a.get('labels', {}).get('alertname') == 'ServiceDown'
                and a.get('labels', {}).get('job') == '${SERVICE}'
                and a.get('status', {}).get('state') == 'active')
    print(count)
except:
    print(0)
" 2>/dev/null || echo "0")

    if [ "${ALERT_COUNT}" -gt 0 ] 2>/dev/null; then
        ALERT_FIRE_SECONDS=$(($(date +%s) - KILL_TIME))
        success "ServiceDown fired at +${ALERT_FIRE_SECONDS}s"

        # Evaluate alert quality
        if [ "${ALERT_FIRE_SECONDS}" -le 30 ]; then
            success "  Grade: FAST (< 30s) — excellent"
        elif [ "${ALERT_FIRE_SECONDS}" -le 60 ]; then
            success "  Grade: GOOD (< 60s) — within SLA"
        elif [ "${ALERT_FIRE_SECONDS}" -le 90 ]; then
            warn "  Grade: ACCEPTABLE (< 90s) — meeting minimum bar"
        else
            fail "  Grade: SLOW (> 90s) — below SLA"
        fi
        ALERT_FIRED=true
        break
    fi
    printf "\r  Elapsed: %ds — no alert yet (checking AlertManager every 5s)" "${ELAPSED}"
done
echo ""

if [ "${ALERT_FIRED}" = false ]; then
    warn "No ServiceDown alert fired in ${ALERT_TIMEOUT}s"
    warn "  Root cause investigation:"
    warn "    docker compose ps alertmanager         # is alertmanager running?"
    warn "    curl http://localhost:9090/api/v1/rules # are rules loaded?"
    warn "    curl http://localhost:9090/targets      # is the scrape target found?"
    ALERT_FIRE_SECONDS="NONE (missed — alert did not fire in ${ALERT_TIMEOUT}s)"
fi

# ── Verify auto-restart ───────────────────────────────────────────────────────
step "Verifying auto-restart (restart: unless-stopped policy)..."

RESTARTED=false
for i in $(seq 1 12); do
    sleep 5
    STATUS=$(docker inspect --format='{{.State.Status}}' "${SERVICE}" 2>/dev/null || echo "unknown")
    if [ "${STATUS}" = "running" ]; then
        info "Container is running at +$((i * 5))s"
        RESTARTED=true
        break
    fi
    printf "\r  Container status: %s (%ds)" "${STATUS}" "$((i * 5))"
done
echo ""

if [ "${RESTARTED}" = false ]; then
    warn "Container did not auto-restart in 60s"
    info "Starting manually..."
    docker compose up -d "${SERVICE}"
fi

# ── Verify healthcheck passes ────────────────────────────────────────────────
step "Waiting for healthcheck to pass (max ${RECOVERY_TIMEOUT}s)..."

HEALTHY=false
RECOVERY_SECONDS=""
for i in $(seq 1 $((RECOVERY_TIMEOUT / 5))); do
    sleep 5
    HEALTH=$(docker inspect --format='{{.State.Health.Status}}' "${SERVICE}" 2>/dev/null || echo "none")
    STATUS=$(docker inspect --format='{{.State.Status}}' "${SERVICE}" 2>/dev/null || echo "unknown")

    if [ "${HEALTH}" = "healthy" ] || ([ "${HEALTH}" = "none" ] && [ "${STATUS}" = "running" ]); then
        RECOVERY_SECONDS=$(($(date +%s) - KILL_TIME))
        success "Container healthy at +${RECOVERY_SECONDS}s"
        HEALTHY=true
        break
    fi
    printf "\r  Health: %-12s | Status: %-12s | Elapsed: %ds" "${HEALTH}" "${STATUS}" "$((i * 5))"
done
echo ""

# ── End-to-end functional verification ───────────────────────────────────────
# This is the critical step that separates real recovery verification from
# "container is running" confirmation.
# A container can be UP but its API can still be broken.
step "End-to-end functional verification (testing actual API response)..."

E2E_PASS=false
E2E_STATUS=""
E2E_NOTE=""

if [ -n "${PORT}" ]; then
    # Wait for the port to be ready
    sleep 3
    HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
        --max-time 5 "http://localhost:${PORT}${HEALTH_PATH}" 2>/dev/null || echo "000")

    if [ "${HTTP_CODE}" = "200" ]; then
        success "Health endpoint returned ${HTTP_CODE}"
        E2E_PASS=true
        E2E_STATUS="PASS (HTTP ${HTTP_CODE})"

        # Service-specific deep verification
        case "${SERVICE}" in
            secureship)
                # Verify the API endpoint actually works (not just health)
                API_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
                    --max-time 5 "http://localhost:${PORT}/api/v1/ships" \
                    -H "X-API-Key: " 2>/dev/null || echo "000")
                if [ "${API_CODE}" = "401" ] || [ "${API_CODE}" = "200" ]; then
                    success "Ships API responding (${API_CODE})"
                    E2E_NOTE="Ships API verified"
                else
                    warn "Ships API returned unexpected ${API_CODE}"
                    E2E_NOTE="WARNING: Ships API returned ${API_CODE}"
                fi
                ;;
            ragservice)
                # Verify RAGService — check if knowledge base is populated
                DOC_COUNT=$(curl -sf --max-time 5 "http://localhost:${PORT}/metrics" 2>/dev/null \
                    | grep "vector_store_documents_total " | awk '{print $2}' || echo "unknown")
                if [ "${DOC_COUNT}" = "0" ] || [ "${DOC_COUNT}" = "0.0" ]; then
                    warn "RAGService is UP but FAISS index is EMPTY (0 documents)"
                    warn "  → Root cause: FAISS is in-memory only — index lost on restart"
                    warn "  → Impact: All queries will return 'I don't have enough context'"
                    warn "  → Fix: POST runbooks to /ingest, or re-deploy (auto-ingest runs)"
                    E2E_NOTE="WARNING: FAISS index empty after restart — re-ingest runbooks"
                    E2E_PASS=false
                elif [ "${DOC_COUNT}" = "unknown" ]; then
                    warn "Could not verify document count"
                    E2E_NOTE="Could not verify FAISS index state"
                else
                    success "RAGService has ${DOC_COUNT} documents in FAISS index"
                    E2E_NOTE="FAISS index has ${DOC_COUNT} documents"
                fi
                ;;
        esac
    else
        fail "Health endpoint returned ${HTTP_CODE} (expected 200)"
        E2E_STATUS="FAIL (HTTP ${HTTP_CODE})"
        E2E_NOTE="Service container is UP but health endpoint is not responding correctly"
    fi
else
    warn "No port configured for ${SERVICE} — skipping functional verification"
    E2E_STATUS="SKIPPED (no port configured)"
fi

# ── Results ───────────────────────────────────────────────────────────────────
EXPERIMENT_END=$(date +%s)
TOTAL_SECONDS=$((EXPERIMENT_END - EXPERIMENT_START))

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  CHAOS EXPERIMENT RESULTS                                ║"
echo "╠══════════════════════════════════════════════════════════╣"
printf "║  Service:         %-38s ║\n" "${SERVICE}"
printf "║  Scenario:        %-38s ║\n" "${SCENARIO}"
printf "║  Alert fired:     %-38s ║\n" "${ALERT_FIRE_SECONDS}s"
printf "║  Container up:    %-38s ║\n" "${RECOVERY_SECONDS:-FAILED}s"
printf "║  API functional:  %-38s ║\n" "${E2E_STATUS}"
printf "║  Total duration:  %-38s ║\n" "${TOTAL_SECONDS}s"
echo "╠══════════════════════════════════════════════════════════╣"
if [ -n "${E2E_NOTE}" ]; then
    printf "║  Note: %-50s ║\n" "${E2E_NOTE}"
    echo "╠══════════════════════════════════════════════════════════╣"
fi

OVERALL_PASS=true
[ "${ALERT_FIRED}" = false ] && OVERALL_PASS=false
[ "${HEALTHY}" = false ] && OVERALL_PASS=false

if [ "${OVERALL_PASS}" = true ] && [ "${E2E_PASS}" = true ]; then
    echo "║  VERDICT:  ✓ PASS — alerting, recovery, and API all working ║"
elif [ "${OVERALL_PASS}" = true ] && [ "${E2E_PASS}" = false ]; then
    echo "║  VERDICT:  ⚠ PARTIAL — container recovered but API degraded  ║"
else
    echo "║  VERDICT:  ✗ FAIL — see findings above                      ║"
fi
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ── Auto-generate postmortem pre-fill ────────────────────────────────────────
step "Generating postmortem pre-fill: ${RESULTS_FILE}"

cat > "${RESULTS_FILE}" << POSTMORTEM
# Postmortem: Chaos Experiment — ${SERVICE} / ${SCENARIO}

**Date:** $(date '+%Y-%m-%d')
**Duration:** $(date -d "@${KILL_TIME}" '+%H:%M:%S' 2>/dev/null || date -r "${KILL_TIME}" '+%H:%M:%S') – $(date '+%H:%M:%S') UTC (${TOTAL_SECONDS}s)
**Type:** Chaos Experiment (deliberate failure injection)
**Status:** Draft — fill in root cause and action items

---

## What We Tested

**Hypothesis:** If we inject failure mode \`${SCENARIO}\` into \`${SERVICE}\`,
then AlertManager will fire ServiceDown within 90 seconds AND the service will
recover fully (API functional) within 120 seconds.

**Failure injected:** ${FAILURE_DESC}

---

## Results

| Measurement | Target | Actual | Status |
|---|---|---|---|
| Alert fires | < 90s | ${ALERT_FIRE_SECONDS}s | $([ "${ALERT_FIRED}" = "true" ] && echo "✓ PASS" || echo "✗ FAIL") |
| Container restart | < 120s | ${RECOVERY_SECONDS:-FAILED}s | $([ "${HEALTHY}" = "true" ] && echo "✓ PASS" || echo "✗ FAIL") |
| API functional | 200 OK | ${E2E_STATUS} | $([ "${E2E_PASS}" = "true" ] && echo "✓ PASS" || echo "✗ FAIL") |
$([ -n "${E2E_NOTE}" ] && echo "| Note | — | ${E2E_NOTE} | ⚠ SEE BELOW |")

---

## Timeline

| Time | Event |
|------|-------|
| +0s | Failure injected: \`${FAILURE_DESC}\` |
| +${ALERT_FIRE_SECONDS:-N/A}s | ServiceDown alert fired in AlertManager |
| +${RECOVERY_SECONDS:-N/A}s | Container restarted and passed healthcheck |
| +${TOTAL_SECONDS}s | End-to-end verification complete |

---

## Root Cause

[FILL IN: What was the actual root cause? Was this a container crash, OOM, dependency failure?
What do the logs say happened?]

\`\`\`bash
# Commands to investigate root cause:
docker inspect ${SERVICE} --format='ExitCode={{.State.ExitCode}} OOMKilled={{.State.OOMKilled}}'
docker logs ${SERVICE} --tail=50 --timestamps 2>&1 | grep -E "ERROR|WARN|exception" -i
\`\`\`

---

## What Went Well

- [FILL IN: e.g., Alert fired within expected window]
- [FILL IN: e.g., Container auto-restarted without manual intervention]
- [FILL IN: e.g., LLM Alert Autopilot correctly diagnosed the failure type]

---

## What Went Badly / Gaps Found

$([ -n "${E2E_NOTE}" ] && echo "- **${E2E_NOTE}**")
- [FILL IN: Any other gaps discovered during this experiment]

---

## Action Items

| Action | Why | Owner | Due |
|--------|-----|-------|-----|
| [FILL IN] | [root cause fix, not symptom treatment] | [name] | YYYY-MM-DD |

---

## Verdict

$([ "${OVERALL_PASS}" = "true" ] && [ "${E2E_PASS}" = "true" ] && echo "**PASS** — alerting, recovery, and end-to-end functionality all verified. System behaves as expected under this failure mode." || echo "**PARTIAL/FAIL** — see action items above. Do not consider this failure mode resolved until action items are closed.")

---

*Generated automatically by \`scripts/chaos.sh\` at $(date '+%Y-%m-%d %H:%M:%S UTC')*
*Full experiment log: run \`bash scripts/chaos.sh ${SERVICE} --scenario=${SCENARIO}\` to reproduce*
POSTMORTEM

success "Postmortem pre-fill saved: ${RESULTS_FILE}"
info "  Fill in 'Root Cause' and 'Action Items' sections"
info "  This file is the record of this chaos experiment"

# ── Final exit code ───────────────────────────────────────────────────────────
if [ "${OVERALL_PASS}" = true ] && [ "${E2E_PASS}" = true ]; then
    exit 0
else
    exit 1
fi
