#!/usr/bin/env bash
# ─── ObserveOps: a five-minute walk through the running stack ─────────────────
# For a screen share. Every line it prints comes from a request it has just made
# to the stack on this machine; nothing is a canned claim. If a step fails it
# says so and carries on, so you can talk about the failure instead of hiding it.
#
#   docker compose up -d        # first, and give it a minute
#   bash scripts/demo.sh
#
# Auth is OFF in the local stack (no API key configured) so the calls below need
# no key. On AWS the same API refuses any request without the X-API-Key header;
# deploy.sh checks that on every deploy.
set -u

BOLD='\033[1m'; BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
section() { echo ""; echo -e "${BOLD}${BLUE}== $* ==${NC}"; }
say()     { echo -e "   $*"; }
good()    { echo -e "   ${GREEN}ok${NC}   $*"; }
bad()     { echo -e "   ${YELLOW}!!${NC}   $*"; }

# python3 on Windows is often a Store stub that prints nothing; prefer `python`.
if python -c "" >/dev/null 2>&1; then PY=python; else PY=python3; fi
code() { curl -s -o /dev/null -m 8 -w '%{http_code}' "$@" 2>/dev/null; }
PROM="http://localhost:9090/prometheus"

# ── 1. Is everything up, and how do we know? ──────────────────────────────────
section "1. What is running"
ALL_UP=true
for target in "nginx (front door)|http://localhost/nginx-health" \
              "SecureShip API|http://localhost:8001/health" \
              "StatusService|http://localhost:8002/health" \
              "RAGService|http://localhost:8003/health" \
              "Alert autopilot|http://localhost:8080/health" \
              "Prometheus|${PROM}/-/healthy" \
              "AlertManager|http://localhost:9093/-/healthy" \
              "Grafana|http://localhost:3000/api/health" \
              "Loki|http://localhost:3100/ready"; do
    name="${target%%|*}"; url="${target##*|}"
    c=$(code "$url")
    if [ "$c" = "200" ]; then good "$name"; else bad "$name answered ${c:-nothing} at $url"; ALL_UP=false; fi
done
if [ "$ALL_UP" = false ]; then
    say ""
    say "Something is not up. Start the stack and wait a minute:  docker compose up -d"
    say "(Loki reports 'not ready' for about 15 s after it starts; that one is normal.)"
fi

say ""
say "That was me asking each service. This is Prometheus asking, every 15 s:"
curl -s -m 8 "${PROM}/api/v1/targets?state=active" | $PY -c "
import sys, json
t = json.load(sys.stdin)['data']['activeTargets']
up = [x for x in t if x['health'] == 'up']
print('   %d of %d scrape targets up' % (len(up), len(t)))
for x in t:
    if x['health'] != 'up':
        print('   DOWN: %s  %s' % (x['labels']['job'], x.get('lastError', '')[:70]))
" 2>/dev/null || bad "could not read Prometheus targets"

# ── 2. The API ────────────────────────────────────────────────────────────────
section "2. SecureShip API (through nginx, the way a user reaches it)"
say "GET /api/v1/ships?limit=2"
curl -s -m 8 "http://localhost/api/v1/ships?limit=2" | $PY -c "
import sys, json
d = json.load(sys.stdin)
print('   total=%s  returned=%s  has_more=%s' % (d.get('total'), len(d.get('ships', [])), d.get('has_more')))
for s in d.get('ships', []): print('   -', s.get('ship_id'), '|', s.get('name'), '|', s.get('status'))
" 2>/dev/null || bad "no JSON came back"

say ""
say "Input is validated before anything is stored. An invalid status:"
c=$(code -X POST "http://localhost/api/v1/ships" -H "Content-Type: application/json" \
        -d '{"ship_id":"demo-1","name":"SS Demo","status":"sunk","cargo":"none"}')
[ "$c" = "422" ] && good "rejected with HTTP 422" || bad "expected 422, got $c"

say ""
say "Every request is counted under its ROUTE, not its URL, so /ships/ship-001 and"
say "/ships/ship-002 are one time series, not two (unbounded labels are how a"
say "metrics store falls over):"
curl -s -m 8 "http://localhost:8001/api/v1/ships/ship-001" >/dev/null
curl -s -m 8 "http://localhost:8001/metrics" | grep '^http_requests_total' | grep 'ship_id' | head -2 | sed 's/^/   /'

# ── 3. The RAG assistant ──────────────────────────────────────────────────────
section "3. RAGService: answers from the runbooks, or says it cannot"
curl -s -m 8 "http://localhost:8003/health" | $PY -c "
import sys, json
d = json.load(sys.stdin)
print('   knowledge base: %s chunks, built from: %s' % (d.get('vector_store_docs'), d.get('knowledge_base_source')))
" 2>/dev/null || bad "RAGService health did not answer"

llm_calls() { curl -s -m 8 "http://localhost:8003/metrics" | awk '/^llm_requests_total/ {s+=$NF} END {print s+0}'; }
BEFORE=$(llm_calls)
say ""
say "Q: SecureShip is showing a high error rate. What should I check first?"
curl -s -m 60 -X POST "http://localhost/ai/query" -H "Content-Type: application/json" \
     -d '{"question":"SecureShip is showing a high error rate. What should I check first?"}' | $PY -c "
import sys, json, textwrap
d = json.load(sys.stdin)
src = sorted({s.get('metadata', {}).get('source', '?') for s in d.get('sources', [])})
print('   grounded: %s   retrieved from: %s' % (d.get('is_relevant'), ', '.join(src)))
for line in textwrap.wrap((d.get('answer') or '').replace(chr(10), ' ')[:420], 76): print('   | ' + line)
" 2>/dev/null || bad "no answer (is GROQ_API_KEY set in .env?)"
MIDDLE=$(llm_calls)

say ""
say "Q: What is the capital of France?   (nothing in the runbooks is about this)"
curl -s -m 60 -X POST "http://localhost/ai/query" -H "Content-Type: application/json" \
     -d '{"question":"What is the capital of France?"}' | $PY -c "
import sys, json
d = json.load(sys.stdin)
print('   grounded: %s' % d.get('is_relevant'))
print('   | ' + (d.get('answer') or '')[:110])
" 2>/dev/null || bad "no answer"
AFTER=$(llm_calls)
say ""
say "LLM calls made: first question $((MIDDLE - BEFORE)), second question $((AFTER - MIDDLE))."
say "The second is 0 by design: retrieval found nothing close enough, so the model"
say "was never asked. It cannot invent an answer it was not given the chance to write."

# ── 4. Alerting ───────────────────────────────────────────────────────────────
section "4. Alerting"
curl -s -m 8 "${PROM}/api/v1/rules" | $PY -c "
import sys, json
g = json.load(sys.stdin)['data']['groups']
alerts = [r for x in g for r in x['rules'] if r['type'] == 'alerting']
firing = [r['name'] for r in alerts if r['state'] == 'firing' and r['name'] != 'Watchdog']
rec = sum(1 for x in g for r in x['rules'] if r['type'] == 'recording')
print('   %d alert rules and %d recording rules loaded' % (len(alerts), rec))
print('   firing right now: %s' % (', '.join(firing) if firing else 'none (Watchdog always fires: it is the heartbeat)'))
" 2>/dev/null || bad "could not read the rules"
say ""
say "The rules have unit tests (synthetic series in, expected alerts out):"
say "   docker run --rm -v \"\$PWD/monitoring/prometheus:/rules\" --entrypoint promtool \\"
say "       prom/prometheus:v3.15.0 test rules /rules/tests/alerts_test.yml"
say ""
say "To watch detection happen, with each stage timed (about 2 minutes):"
say "   bash scripts/chaos.sh secureship"
say "To practise diagnosing a failure you were not told about:"
say "   python scripts/gameday.py start"

# ── 5. Where to look ──────────────────────────────────────────────────────────
section "5. Where to look"
say "Grafana      http://localhost:3000/grafana/     admin / observeops123 (local only)"
say "Prometheus   ${PROM}/"
say "AlertManager http://localhost:9093"
say "Log pipeline http://localhost:9080/graph        (Alloy's component graph)"
say "Decisions    docs/adr/        what was chosen, what it cost, what is still wrong"
say "Runbooks     docs/runbooks/   the same files the assistant answers from"
echo ""
