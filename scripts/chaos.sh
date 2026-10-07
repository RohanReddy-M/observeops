#!/bin/bash
# ─── Chaos Engineering ────────────────────────────────────────────────────────
# Inject a failure on purpose, then measure what the platform actually does
# about it. A monitoring stack you have never seen fire is a hypothesis.
#
#   bash scripts/chaos.sh [service] [--scenario=kill|crash|oom|depkill] [--force]
#
#   bash scripts/chaos.sh ragservice                    # default scenario: kill
#   bash scripts/chaos.sh secureship --scenario=crash
#   bash scripts/chaos.sh ragservice --scenario=oom
#   bash scripts/chaos.sh secureship --scenario=depkill
#
# Each scenario tests a DIFFERENT thing. Mixing them up is how you end up
# "verifying" something the experiment never exercised.
#
#   kill     `docker kill`. The container dies and STAYS down: Docker treats
#            `docker kill` as an operator stopping the container, so the restart
#            policy does not apply. This tests DETECTION. ServiceDown has
#            `for: 1m`, so it cannot fire sooner than 60 s after the kill and
#            should fire within 60-90 s (up to ~105 s on a host whose rule
#            evaluator trails the clock; scripts/alert_timeline.py explains
#            both). The script then starts the service again and times recovery.
#
#   crash    The main process is told to exit from inside the container, as a
#            real crash would. The restart policy DOES apply. This tests
#            SELF-HEALING: the service should be healthy again with nobody
#            touching it, and ServiceDown should NOT fire, because the outage is
#            shorter than the rule's one-minute `for:` window. An alert that
#            pages for something that already fixed itself is noise.
#
#   oom      The container is recreated with a memory limit far too small for it
#            to start (and no swap), so the kernel OOM-kills the main process
#            (exit code 137, OOMKilled = true) and keeps killing it on every
#            restart. This is a real OOM loop, not a simulation. The container
#            is recreated with its normal limit afterwards.
#
#   depkill  Loki is killed. Tests that losing the log store is detected
#            (LokiDown, `for: 2m`, so 120-165 s) and that the services keep
#            serving without it.
#
# Output: a postmortem pre-fill in docs/postmortems/ with the measured timeline.

set -euo pipefail
cd "$(dirname "$0")/.."

SERVICE="${1:-secureship}"
SCENARIO="kill"
FORCE=false
for arg in "$@"; do
    case $arg in
        --scenario=*) SCENARIO="${arg#*=}" ;;
        --force)      FORCE=true ;;
    esac
done

POSTMORTEM_DIR="docs/postmortems"
RECOVERY_TIMEOUT=180

# Where Prometheus and AlertManager are. Locally that is this machine. On the
# two-server deployment they live on the observability server, whose address
# deploy.sh records in .env.
OBS_HOST="localhost"
if [ -f .env ]; then
    ENV_OBS=$(grep -E '^OBS_SERVER_IP=' .env | cut -d= -f2- || true)
    [ -n "${ENV_OBS:-}" ] && OBS_HOST="$ENV_OBS"
fi
PROMETHEUS_URL="${PROMETHEUS_URL:-http://${OBS_HOST}:9090/prometheus}"
ALERTMANAGER_URL="${ALERTMANAGER_URL:-http://${OBS_HOST}:9093}"

declare -A SERVICE_PORTS=( [secureship]=8001 [statusservice]=8002 [ragservice]=8003 [llm-alert-autopilot]=8080 )

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}    $*"; }
success() { echo -e "${GREEN}[PASS]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}    $*"; }
fail()    { echo -e "${RED}[FAIL]${NC}    $*"; }
step()    { echo -e "${CYAN}[STEP]${NC}    $*"; }

# python3 on Linux and macOS; on Windows `python3` is often a Store stub that
# prints a message and exits, so check that the interpreter really runs.
PY=""
for candidate in python3 python; do
    if "$candidate" -c "import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)" >/dev/null 2>&1; then
        PY="$candidate"; break
    fi
done
[ -n "$PY" ] || { fail "Python 3 is required (for scripts/alert_timeline.py)"; exit 1; }
now() { "$PY" -c "import time; print(time.time())"; }
since() { "$PY" -c "import sys, time; print(int(round(time.time() - float(sys.argv[1]))))" "$1"; }

if ! docker compose ps --services 2>/dev/null | grep -q "^${SERVICE}$"; then
    fail "Service '${SERVICE}' is not running. Running services:"
    docker compose ps --services | sed 's/^/  /'
    exit 1
fi

# What we expect each scenario to do to the alerting pipeline.
TARGET="$SERVICE"; ALERT="ServiceDown"; EXPECT_ALERT=true; ALERT_TIMEOUT=150; WINDOW="60-105"
case "$SCENARIO" in
    kill)    ;;
    oom)     ;;
    crash)   EXPECT_ALERT=false ;;
    depkill) TARGET="loki"; ALERT="LokiDown"; ALERT_TIMEOUT=240; WINDOW="120-165" ;;
    *)       fail "Unknown scenario '${SCENARIO}'. Valid: kill, crash, oom, depkill"; exit 1 ;;
esac
PORT="${SERVICE_PORTS[$SERVICE]:-}"

EXPERIMENT_DATE=$(date '+%Y-%m-%d_%H-%M-%S')
RESULTS_FILE="${POSTMORTEM_DIR}/${EXPERIMENT_DATE}-chaos-${SERVICE}-${SCENARIO}.md"
mkdir -p "$POSTMORTEM_DIR"

echo ""
echo "  ObserveOps chaos experiment"
echo "  service:  ${SERVICE}      scenario: ${SCENARIO}      target of failure: ${TARGET}"
echo "  expect:   $([ "$EXPECT_ALERT" = true ] && echo "${ALERT} firing ${WINDOW} s after injection" || echo "self-healing with NO page (outage shorter than the alert's for: window)")"
echo ""

# ── 1. A clean baseline ───────────────────────────────────────────────────────
# Timing an alert that was already pending or firing measures nothing. The old
# version of this script never checked, which is one way to record an alert
# "firing" faster than its own `for:` duration allows.
step "Checking for a clean baseline..."
if ! "$PY" scripts/alert_timeline.py --job "$TARGET" --alert "$ALERT" \
        --prom "$PROMETHEUS_URL" --am "$ALERTMANAGER_URL" --preflight; then
    if [ "$FORCE" = true ]; then
        warn "Baseline is not clean; continuing because of --force. Timings will not be trustworthy."
    else
        fail "Refusing to run from a dirty baseline. Wait for the alert to resolve, or pass --force."
        exit 1
    fi
fi

# ── 2. Inject the failure ─────────────────────────────────────────────────────
ORIGINAL_MEMORY=""
# Remember when the container last started. "Recovered" only means something once
# this has changed: a container that has not restarted yet still reports its OLD
# health status, and reading that back as a recovery is measuring nothing.
STARTED_BEFORE=$(docker inspect --format '{{.State.StartedAt}}' "$TARGET" 2>/dev/null || echo "")
step "Injecting failure (${SCENARIO})..."
T0=$(now)       # taken BEFORE the injection, so no part of the outage is lost
case "$SCENARIO" in
    kill)
        docker compose kill "$TARGET" >/dev/null
        FAILURE_DESC="docker kill (SIGKILL): the container is gone and will not be restarted by Docker"
        ;;
    depkill)
        docker compose kill "$TARGET" >/dev/null
        FAILURE_DESC="dependency killed: ${TARGET} (docker kill)"
        ;;
    crash)
        # PID 1 only receives signals it has a handler for; uvicorn and gunicorn
        # both handle SIGTERM by exiting, which is what a crash looks like to Docker.
        docker exec "$TARGET" python -c "import os, signal; os.kill(1, signal.SIGTERM)" || true
        FAILURE_DESC="main process exited on its own (SIGTERM delivered to PID 1 inside the container)"
        ;;
    oom)
        # Recreate the container with a 32 MiB limit rather than `docker update` the
        # running one. Two reasons, both found by trying the other way first:
        #  - on cgroup v1 the kernel refuses to lower memory+swap below current usage
        #    ("device or resource busy"), after the memory limit itself has already
        #    been lowered, which leaves the container half-changed;
        #  - with swap still allowed the process is not killed at all, it is swapped
        #    out and limps on. memswap_limit equal to the memory limit means no swap,
        #    so exceeding the limit is an OOM kill.
        ORIGINAL_MEMORY=$(docker inspect --format '{{.HostConfig.Memory}}' "$TARGET")
        USED=$(docker stats --no-stream --format '{{.MemUsage}}' "$TARGET" | cut -d/ -f1 | tr -d ' ')
        info "Memory in use: ${USED}; limit $((ORIGINAL_MEMORY / 1024 / 1024))MiB. Recreating with a 32MiB limit and no swap."
        OOM_OVERRIDE="$(mktemp -d)/oom-override.yml"
        cat > "$OOM_OVERRIDE" <<YAML
services:
  ${TARGET}:
    memswap_limit: 32M
    deploy:
      resources:
        limits:
          memory: 32M
        reservations:
          memory: 16M
YAML
        docker compose -f docker-compose.yml -f "$OOM_OVERRIDE" up -d --no-deps "$TARGET" >/dev/null 2>&1 || true
        FAILURE_DESC="container recreated with a 32MiB memory limit and no swap: the kernel OOM-kills it on every start"
        ;;
esac
info "Injected at +0s: ${FAILURE_DESC}"

# ── 3. Measure the alerting pipeline, stage by stage ──────────────────────────
SCRAPE=NONE; PENDING=NONE; FIRING=NONE; AM=NONE
if [ "$EXPECT_ALERT" = true ]; then
    step "Measuring the alert pipeline (scrape -> pending -> firing -> AlertManager)..."
    TIMELINE_OUT=$("$PY" scripts/alert_timeline.py --job "$TARGET" --alert "$ALERT" \
        --prom "$PROMETHEUS_URL" --am "$ALERTMANAGER_URL" --t0 "$T0" --timeout "$ALERT_TIMEOUT" || true)
    echo "$TIMELINE_OUT" | grep -v '^TIMELINE '
    SUMMARY=$(echo "$TIMELINE_OUT" | grep '^TIMELINE ' || echo "")
    for pair in $SUMMARY; do
        case "$pair" in
            SCRAPE_FAILED=*) SCRAPE="${pair#*=}" ;;
            PENDING=*)       PENDING="${pair#*=}" ;;
            FIRING=*)        FIRING="${pair#*=}" ;;
            ALERTMANAGER=*)  AM="${pair#*=}" ;;
        esac
    done
    if [ "$FIRING" = "NONE" ]; then
        fail "${ALERT} did not fire within ${ALERT_TIMEOUT}s"
        ALERT_VERDICT="FAIL (did not fire)"
    else
        success "${ALERT} firing at +${FIRING}s (expected window ${WINDOW}s)"
        ALERT_VERDICT="PASS (+${FIRING}s)"
    fi
else
    ALERT_VERDICT="not expected"
fi

# ── 4. Recovery ───────────────────────────────────────────────────────────────
step "Recovery..."
T_RESTORE=$(now)
case "$SCENARIO" in
    kill|depkill)
        info "Starting ${TARGET} again (this is the human-fixes-it step; Docker would never restart it)."
        docker compose up -d "$TARGET" >/dev/null 2>&1
        ;;
    oom)
        docker inspect --format '  observed: exit code {{.State.ExitCode}}, OOMKilled={{.State.OOMKilled}}, restarts={{.RestartCount}}' "$TARGET" || true
        info "Recreating ${TARGET} with its normal $((ORIGINAL_MEMORY / 1024 / 1024))MiB limit."
        docker compose up -d --no-deps "$TARGET" >/dev/null 2>&1
        ;;
    crash)
        info "Doing nothing. The restart policy is what is being tested."
        T_RESTORE="$T0"
        ;;
esac

HEALTHY=false; RECOVERY_SECONDS="FAILED"
for _ in $(seq 1 $((RECOVERY_TIMEOUT / 3))); do
    STARTED_NOW=$(docker inspect --format '{{.State.StartedAt}}' "$TARGET" 2>/dev/null || echo "")
    if [ "$STARTED_NOW" = "$STARTED_BEFORE" ]; then
        sleep 1; continue      # the original process is still the one running
    fi
    HEALTH=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$TARGET" 2>/dev/null || echo "unknown")
    STATUS=$(docker inspect --format '{{.State.Status}}' "$TARGET" 2>/dev/null || echo "unknown")
    if [ "$HEALTH" = "healthy" ] || { [ "$HEALTH" = "none" ] && [ "$STATUS" = "running" ]; }; then
        RECOVERY_SECONDS=$(since "$T_RESTORE"); HEALTHY=true
        success "${TARGET} healthy ${RECOVERY_SECONDS}s after $([ "$SCENARIO" = crash ] && echo "the crash, with no intervention" || echo "it was started again")"
        break
    fi
    sleep 3
done
[ "$HEALTHY" = true ] || fail "${TARGET} did not become healthy within ${RECOVERY_TIMEOUT}s"

if [ "$SCENARIO" = crash ] && [ "$HEALTHY" = true ]; then
    sleep 20      # give one scrape and one evaluation the chance to disagree
    if "$PY" scripts/alert_timeline.py --job "$TARGET" --alert "$ALERT" \
            --prom "$PROMETHEUS_URL" --am "$ALERTMANAGER_URL" --preflight >/dev/null 2>&1; then
        success "No ${ALERT} was raised: the outage ended inside the alert's for: window, as designed"
        ALERT_VERDICT="PASS (correctly silent)"
    else
        warn "${ALERT} is pending or firing even though the service healed itself"
        ALERT_VERDICT="WARN (alert raised for a self-healed outage)"
    fi
fi

# ── 5. Does it actually work, or is it only running? ──────────────────────────
# A container can be up, pass its health check, and still be useless. This is
# the check that found the empty vector index after a restart.
step "End-to-end functional verification..."
E2E_PASS=false; E2E_STATUS="skipped"; E2E_NOTE=""
if [ -n "$PORT" ] && [ "$HEALTHY" = true ]; then
    CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://localhost:${PORT}/health" || echo "000")
    if [ "$CODE" = "200" ]; then
        E2E_PASS=true; E2E_STATUS="PASS (health 200)"
        case "$SERVICE" in
            secureship)
                KEY=$(grep -E '^SECURESHIP_API_KEY=' .env 2>/dev/null | cut -d= -f2- || true)
                API=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 ${KEY:+-H "X-API-Key: ${KEY}"} \
                      "http://localhost:${PORT}/api/v1/ships?limit=1" || echo "000")
                if [ "$API" = "200" ]; then E2E_NOTE="Ships API returned data (200)"
                else E2E_PASS=false; E2E_NOTE="Ships API returned ${API}, expected 200"; fi
                ;;
            ragservice)
                DOCS=$(curl -s --max-time 5 "http://localhost:${PORT}/health" | "$PY" -c "import json,sys; print(json.load(sys.stdin).get('vector_store_docs', -1))" 2>/dev/null || echo "-1")
                if [ "$DOCS" = "0" ]; then
                    E2E_PASS=false
                    E2E_NOTE="ZOMBIE: healthy but the vector index is empty, so every answer will be 'not enough context'"
                else
                    E2E_NOTE="vector index holds ${DOCS} chunks after recovery"
                fi
                ;;
        esac
    else
        E2E_STATUS="FAIL (health ${CODE})"
    fi
    [ "$E2E_PASS" = true ] && success "${E2E_NOTE:-health endpoint OK}" || warn "${E2E_NOTE:-functional check failed}"
fi

# ── 6. Verdict ────────────────────────────────────────────────────────────────
OVERALL=PASS
case "$ALERT_VERDICT" in FAIL*) OVERALL=FAIL ;; esac
[ "$HEALTHY" = true ] || OVERALL=FAIL
if [ "$OVERALL" = PASS ] && [ -n "$PORT" ] && [ "$E2E_PASS" != true ]; then OVERALL=PARTIAL; fi

echo ""
echo "  RESULT: ${OVERALL}"
echo "    alerting:   ${ALERT_VERDICT}"
[ "$EXPECT_ALERT" = true ] && echo "    stages:     scrape failed +${SCRAPE}s | pending +${PENDING}s | firing +${FIRING}s | in AlertManager +${AM}s"
echo "    recovery:   ${RECOVERY_SECONDS}s"
echo "    functional: ${E2E_STATUS}${E2E_NOTE:+ — ${E2E_NOTE}}"
echo ""

# ── 7. Postmortem pre-fill ────────────────────────────────────────────────────
cat > "$RESULTS_FILE" << POSTMORTEM
# Postmortem: Chaos Experiment — ${SERVICE} / ${SCENARIO}

**Date:** $(date '+%Y-%m-%d %H:%M:%S %Z')
**Type:** Chaos experiment (deliberate failure injection)
**Status:** Draft — fill in what you learned and the action items

## What was tested

**Failure injected:** ${FAILURE_DESC}

**Expectation:** $([ "$EXPECT_ALERT" = true ] && echo "${ALERT} firing ${WINDOW} seconds after injection; ${TARGET} serving again once restarted." || echo "${TARGET} healthy again with no intervention, and no ${ALERT} page, because the outage is shorter than the rule's \`for:\` window.")

## Measured

| Stage | Seconds after injection | What it is |
|---|---|---|
| Scrape failed | ${SCRAPE} | Prometheus's next scrape of the target failed (0 to one 15 s scrape interval) |
| Pending | ${PENDING} | the next rule evaluation saw it (0 to one 15 s evaluation interval later) |
| Firing | ${FIRING} | the rule's \`for:\` duration elapsed |
| In AlertManager | ${AM} | Prometheus delivered the alert |

Notifications (Slack, the autopilot webhook) follow up to \`group_wait\` (30 s) after the last row.

| Check | Result |
|---|---|
| Alerting | ${ALERT_VERDICT} |
| Recovery | ${RECOVERY_SECONDS}s $([ "$SCENARIO" = crash ] && echo "(self-healed)" || echo "(after being started again)") |
| Functional | ${E2E_STATUS}${E2E_NOTE:+ — ${E2E_NOTE}} |
| **Overall** | **${OVERALL}** |

## Root cause

[This was a deliberate injection, so the cause is known. Write down what the SYSTEM did that
you did not expect.]

\`\`\`bash
docker inspect ${TARGET} --format 'ExitCode={{.State.ExitCode}} OOMKilled={{.State.OOMKilled}} Restarts={{.RestartCount}}'
docker logs ${TARGET} --tail 50 --timestamps
\`\`\`

## What went well

- [FILL IN]

## What went badly, or gaps found

$([ -n "$E2E_NOTE" ] && [ "$E2E_PASS" != true ] && echo "- **${E2E_NOTE}**")
- [FILL IN]

## Action items

| Action | Why | Owner | Due |
|---|---|---|---|
| [FILL IN] | [fixes the cause, not the symptom] | | |

---
*Generated by \`scripts/chaos.sh ${SERVICE} --scenario=${SCENARIO}\`. Timings come from \`scripts/alert_timeline.py\`.*
POSTMORTEM
info "Postmortem pre-fill written: ${RESULTS_FILE}"

[ "$OVERALL" = PASS ] && exit 0 || exit 1
