# Postmortem: [Incident Title]

**Date:** YYYY-MM-DD
**Duration:** HH:MM – HH:MM UTC (X hours Y minutes)
**Severity:** SEV-1 (customer-facing outage) / SEV-2 (degraded) / SEV-3 (internal only)
**Status:** Draft / In Review / Closed
**Author:** [name]
**Reviewers:** [names]

---

## Impact

What broke, for how long, and for whom.

- **Services affected:** SecureShip API / RAGService / StatusService / Monitoring stack
- **Users/customers affected:** All users / subset / internal only
- **Requests affected:** X% of traffic (Y requests/minute failing)
- **SLO impact:** Error budget consumed: ~X minutes of the 216-minute monthly budget
- **Revenue impact:** (if applicable)

---

## Timeline

*All times in UTC. Record when things happened, not when you discovered them.*

| Time  | Event |
|-------|-------|
| HH:MM | First alert fires: [alert name] |
| HH:MM | On-call acknowledges |
| HH:MM | Initial hypothesis: [what you thought it was] |
| HH:MM | Hypothesis ruled out: [why it wasn't that] |
| HH:MM | Root cause identified: [what it actually was] |
| HH:MM | Mitigation deployed: [what fixed it] |
| HH:MM | Service restored (all healthchecks passing) |
| HH:MM | Incident declared resolved |

---

## Root Cause

One paragraph. Explain the technical cause precisely — not "the server was slow" but "the RAGService pod's FAISS index was empty because the auto-ingest step in deploy.sh timed out when Groq was rate-limited during deploy, leaving the vector store with zero documents. All RAG queries returned ungrounded responses."

---

## Contributing Factors

Not the root cause, but things that made it worse or harder to debug:

- (e.g.) Alert didn't fire for 3 minutes because Prometheus evaluation interval was 15s and `for: 1m` gate
- (e.g.) Runbook pointed to wrong Docker service name — caused 5-minute delay finding the right container
- (e.g.) Deploy happened at 10pm local time, reduced team availability

---

## What Went Well

Important: postmortems are not blame documents. Record what worked.

- (e.g.) LLM Alert Autopilot correctly identified the root cause from logs within 30 seconds of alert firing
- (e.g.) Rollback script executed in 45 seconds with zero additional downtime
- (e.g.) OTel traces made it immediately clear which service in the chain was failing

---

## What Went Badly

Honest assessment. Not who — what.

- (e.g.) No alert covered the "FAISS index empty" condition — ungrounded rate was the only signal and it fired 8 minutes late
- (e.g.) Recovery required manual SSH (SSM session manager wasn't documented in runbook)
- (e.g.) Grafana dashboard showed the wrong service on the SLO panel — misleading during investigation

---

## Action Items

Each item needs an owner and a due date. Without these, postmortems don't improve anything.

| Action | Owner | Due | Status |
|--------|-------|-----|--------|
| Add alert: RAGService vector store empty at startup | [name] | YYYY-MM-DD | Open |
| Update runbook: add correct docker service names | [name] | YYYY-MM-DD | Open |
| Add chaos test for ingest failure scenario | [name] | YYYY-MM-DD | Open |

---

## Lessons

What specific, generalizable lessons does this incident produce?

1. **Lesson (technical):** [specific insight about the system or tooling]
2. **Lesson (process):** [specific insight about how the team responds]
3. **Lesson (monitoring):** [gap in observability that this exposed]

---

## Detection Delay Analysis

*Fill this in for every incident — it forces you to think about monitoring gaps.*

| Stage | Expected | Actual | Gap |
|-------|----------|--------|-----|
| Alert fires after failure | <90s | Xs | Y seconds |
| On-call notified after alert | <2min | Xmin | — |
| Root cause identified | <30min | Xmin | — |
| Mitigation deployed | <60min | Xmin | — |
| Service restored | <90min | Xmin | — |

---

## References

- Alert that fired: [link to Grafana/AlertManager]
- Relevant Grafana dashboard: [link]
- LLM diagnosis from Alert Autopilot: [paste here]
- Related GitHub issue/PR: [link]
- Previous postmortems with similar root cause: [link]
