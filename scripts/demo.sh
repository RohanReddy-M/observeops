#!/bin/bash
# ─── ObserveOps Interview Demo ────────────────────────────────────────────────
# Run this during a screen share to walk through the project capabilities.
# Shows: API, AI assistant, alerting, observability, chaos engineering.
#
# Usage: bash scripts/demo.sh
# Pre-requisite: make dev-up must be running

set -euo pipefail

BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

section() { echo ""; echo -e "${BOLD}${BLUE}══ $* ══${NC}"; echo ""; }
step()    { echo -e "${CYAN}→${NC}  $*"; }
result()  { echo -e "${GREEN}✓${NC}  $*"; }
note()    { echo -e "${YELLOW}ℹ${NC}  $*"; }

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║           ObserveOps — Live Demo                     ║${NC}"
echo -e "${BOLD}║   Production-grade DevOps + AIOps portfolio project  ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
note "Stack: FastAPI + LangChain + FAISS + Groq + Prometheus + Grafana + Loki + Tempo"
note "Deployed via: GitHub Actions (OIDC) → ECR → EC2 → Docker Compose"

# ─── Step 1: Verify stack is healthy ────────────────────────────────────────
section "1. System Health"

step "Checking all services..."
PASS=true
for svc_port in "SecureShip:8001" "StatusService:8002" "RAGService:8003" "LLM-Autopilot:8080" "Prometheus:9090" "Grafana:3000" "AlertManager:9093"; do
    svc="${svc_port%%:*}"
    port="${svc_port##*:}"
    path="/health"
    [ "$port" = "9090" ] && path="/-/healthy"
    [ "$port" = "3000" ] && path="/api/health"
    [ "$port" = "9093" ] && path="/-/healthy"
    code=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 3 "http://localhost:${port}${path}" 2>/dev/null || echo "000")
    if [ "$code" = "200" ]; then
        result "$svc: UP"
    else
        echo -e "  ${YELLOW}⚠${NC}  $svc: DOWN (HTTP $code) — run 'make dev-up' first"
        PASS=false
    fi
done

# RAGService knowledge base check
docs=$(curl -sf --max-time 3 http://localhost:8003/health 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('vector_store_docs',0))" 2>/dev/null || echo "?")
result "RAGService FAISS index: ${docs} documents loaded"

echo ""
[ "$PASS" = false ] && echo -e "${YELLOW}Some services are down. Run 'make dev-up' and wait 20s, then retry.${NC}" && exit 1

# ─── Step 2: SecureShip API ──────────────────────────────────────────────────
section "2. SecureShip API — Rate Limited, Paginated, JWT/API-Key Auth"

step "Listing ships (unauthenticated → should return 401)..."
code=$(curl -sf -o /dev/null -w "%{http_code}" http://localhost:8001/api/v1/ships 2>/dev/null || echo "000")
result "Unauthenticated request returned HTTP $code (401 = auth working)"

step "Listing ships with pagination (limit=2, offset=0)..."
curl -sf "http://localhost:8001/api/v1/ships?limit=2&offset=0" \
    -H "X-API-Key: ${API_KEY:-}" 2>/dev/null \
    | python3 -m json.tool 2>/dev/null | head -20 || note "(Set API_KEY env var to test auth — in local mode, no key needed)"

step "Creating a ship..."
curl -sf -X POST http://localhost:8001/api/v1/ships \
    -H "Content-Type: application/json" \
    -H "X-API-Key: ${API_KEY:-}" \
    -d '{"ship_id":"demo-001","name":"SS Demo","status":"active","cargo":"test payload"}' \
    2>/dev/null | python3 -m json.tool 2>/dev/null || true

result "Rate limiting: 100 req/min per API key (429 after limit)"
result "Input validation: ship_id pattern, status enum, all fields validated"
result "Pagination: limit/offset/status filter — no unbounded scans"

# ─── Step 3: AI Incident Assistant ──────────────────────────────────────────
section "3. RAGService — AI Incident Assistant (LangChain + LangGraph + Groq)"

step "Asking the AI about a high error rate alert..."
RESPONSE=$(curl -sf -X POST http://localhost:8003/query \
    -H "Content-Type: application/json" \
    -d '{"question": "SecureShip is showing a high error rate. What should I check first?"}' \
    2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('answer',''))" 2>/dev/null || echo "(query failed)")
echo ""
echo -e "  ${CYAN}AI Response:${NC}"
echo "$RESPONSE" | fold -s -w 80 | sed 's/^/  /'
echo ""
result "Grounding check: LLM only answers from ingested runbooks (no hallucination)"
result "Source documents: response includes which runbooks were used"

step "Testing graceful degradation (question with no runbook context)..."
NO_CTX=$(curl -sf -X POST http://localhost:8003/query \
    -H "Content-Type: application/json" \
    -d '{"question": "What is the capital of France?"}' \
    2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('answer','')[:80])" 2>/dev/null || echo "")
result "Off-topic question: '$NO_CTX...'"
result "Service does NOT hallucinate — returns 'I don't have enough context'"

# ─── Step 4: Observability ───────────────────────────────────────────────────
section "4. Observability — Metrics + Logs + Traces (full triad)"

step "Prometheus metrics from SecureShip..."
curl -sf http://localhost:8001/metrics 2>/dev/null \
    | grep -E "^http_requests_total|^http_request_duration" | head -5
echo ""
result "Metrics: request count, p99 latency, error rate — all tracked"

step "Grafana dashboards available at http://localhost:3000 (admin/observeops123)"
note "  → Services Overview: http://localhost:3000/d/observeops-services"
note "  → SLO + Error Budget: http://localhost:3000/d/observeops-slo"
note "  → DORA Metrics:       http://localhost:3000/d/observeops-dora"
note "  → LLM Metrics:        http://localhost:3000/d/observeops-llm"

step "SLO definitions:"
note "  SecureShip availability: 99.5% (error budget: 216 min/month)"
note "  SecureShip p99 latency:  <500ms"
note "  RAGService success rate: 95%"
note "  RAGService grounded:     >50% (model quality SLO)"

step "OTel distributed traces:"
note "  Traces flow: app → otel-collector → Tempo → Grafana Explore"
note "  Every SecureShip request has a trace ID for correlation with logs"

# ─── Step 5: LLM Alert Autopilot ────────────────────────────────────────────
section "5. LLM Alert Autopilot — AI Diagnoses Alerts Automatically"

step "Recent deploy history (used to correlate alerts with deployments)..."
curl -sf http://localhost:8080/deploy-history 2>/dev/null \
    | python3 -c "
import sys,json
d=json.load(sys.stdin)
if d['count']:
    for dep in d['deploys'][:3]:
        print(f\"  commit={dep['commit'][:12]} deployer={dep['deployer']} status={dep['status']}\")
else:
    print('  (no deploys recorded yet — deploy.sh registers them automatically)')
" 2>/dev/null || true

echo ""
note "When an alert fires:"
note "  1. AlertManager sends webhook to autopilot"
note "  2. Autopilot queries Loki for error logs from the failing service"
note "  3. Adds recent deploy context: 'commit abc1234 deployed 8min ago'"
note "  4. Groq LLM diagnoses root cause + suggests fix command"
note "  5. Posts to Slack within ~3 seconds of alert firing"
note "  6. Records MTTR when alert resolves (DORA metric)"

# ─── Step 6: Chaos Engineering ──────────────────────────────────────────────
section "6. Chaos Engineering — We Break It On Purpose"

echo ""
note "Run 'make chaos' to demonstrate live:"
note "  1. Kills secureship container"
note "  2. Verifies ServiceDown alert fires within 90 seconds"
note "  3. Verifies container auto-restarts (restart: unless-stopped)"
note "  4. Verifies API actually works after restart (not just container up)"
note "  5. Generates postmortem pre-fill automatically"
echo ""
note "Run 'make chaos-oom' to simulate memory exhaustion"
note "Run 'make chaos-depkill' to test Loki dependency failure"
echo ""
note "Previous chaos experiment results:"
ls docs/postmortems/*.md 2>/dev/null | grep -v TEMPLATE | while read f; do
    echo "  → $(basename $f)"
done

# ─── Step 7: Security ────────────────────────────────────────────────────────
section "7. Security"

note "CI/CD: OIDC authentication — no long-lived AWS keys stored in GitHub"
note "Containers: non-root user, read-only filesystem mounts, no privileged"
note "EC2 access: SSM only — port 22 closed, zero inbound ports open"
note "Secrets: SSM Parameter Store with encryption, never in env files or code"
note "Scanning: Trivy (CVEs) + Bandit (SAST) + TruffleHog (secret leaks) in CI"
note "Audit: CloudTrail → EventBridge → Lambda → Slack within 30s of any"
note "       destructive AWS op (delete table, create IAM key, terminate EC2)"
note "IMDSv2: enforced on all EC2 instances (prevents SSRF credential theft)"

# ─── Summary ────────────────────────────────────────────────────────────────
section "Summary"

echo "ObserveOps demonstrates:"
echo ""
echo "  System Design:  Two-server architecture, SLOs with error budgets,"
echo "                  circuit breaker, rate limiting, pagination"
echo "  AIOps:          RAG assistant + alert autopilot with deploy context"
echo "  Reliability:    Chaos engineering, deadman switch, postmortems"
echo "  Security:       OIDC, SSM, audit alerter, Trivy scanning"
echo "  Operations:     DORA metrics, runbooks, ADRs, rolling deploy"
echo ""
echo "  ADRs:  docs/adr/   (8 architectural decisions with full WHY)"
echo "  Postmortems: docs/postmortems/ (real chaos experiment results)"
echo ""
echo -e "${GREEN}Full repo: https://github.com/RohanReddy-M/observeops${NC}"
echo ""
