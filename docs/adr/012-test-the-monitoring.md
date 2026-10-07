# ADR-012: The Monitoring Is Code, So It Is Tested and Measured

**Status:** Accepted
**Date:** 2026-10-07

---

## Context

A review of this project in October 2026 found the following, none of which had ever caused a visible failure:

| What | Why it could not work |
|---|---|
| Five alert rules (error rates, LLM error rate, ungrounded rate) | Written as `rate(errors) / rate(all)` with no aggregation, so each series was divided by itself: 100% whenever one error existed |
| `ContainerRestartingFrequently` | Queried a Kubernetes metric that does not exist in a Docker Compose deployment |
| Host alerts (CPU, memory, disk) | Watched the monitoring host while labelled as the application host, which had no host metrics at all |
| The MTTR histogram | Never received an observation: resolved notifications were not sent, and the timestamp parser failed on the format Prometheus uses |
| The deployment-frequency panel | A commit SHA label turned one counter into one series per deploy |
| The deadman switch | The always-firing alert was routed to a receiver with no destination |
| The LLM diagnosis | Called a retired model, and had never been able to fetch a log line |
| The recorded detection time, "+42s" | Not possible for a rule with `for: 1m` |

The common cause is not carelessness in any one of them. It is that **a broken monitor is silent.** Application bugs produce errors, and errors get noticed. An alert that can never fire produces nothing, which looks exactly like a healthy system. Nothing in this project checked the monitoring the way the monitoring checked the application.

## Decision

Treat alert rules, the alert pipeline and the diagnosis path as software that needs its own evidence:

1. **Alert rules have unit tests.** `monitoring/prometheus/tests/alerts_test.yml` runs under `promtool test rules` in CI: synthetic series in, an exact list of expected alerts out, including negative cases (a 2% error rate must fire nothing).
2. **Config is validated in CI.** `promtool check rules` and `amtool check-config` run on every push.
3. **Detection time is measured, not stated.** `scripts/alert_timeline.py` records when each stage becomes observable after an injected failure, from a baseline it first verifies is clean.
4. **Chaos scenarios name what they test.** `kill` tests detection; `crash` tests self-healing and expects no page; `oom` is a real OOM loop. A scenario that restarts the service itself may not claim to have verified auto-restart.
5. **The diagnosis path has its own alert**, and retrieval quality has deterministic tests against the real embedding model.

## Rationale

**Why unit tests for rules, when the rules are "just YAML".** The self-division bug is a one-line PromQL mistake that reads correctly to a human. A test with a 2% error rate and an assertion that nothing fires catches it mechanically. The same test documents the intended threshold better than a comment.

**Why measure the stages separately.** "The alert fired in N seconds" cannot be checked against the design. "Scrape failed at +2s, pending at +17s, firing at +77s" can: the gap between pending and firing must equal the rule's `for:` duration, and it does. That decomposition is what exposed the old figure as impossible, and later showed that on one host the rule evaluator trails the wall clock by an interval.

**Why negative tests matter more than positive ones here.** An alert that fires when it should not is found quickly, because it annoys someone. An alert that does not fire when it should is found during the incident it was written for. The tests therefore assert both directions.

## Alternatives considered

*Rely on chaos experiments alone.* They test the path that was exercised that day. They did not catch any of the eight items above, partly because the experiment script had its own measurement errors.

*Synthetic monitoring from outside (blackbox probes).* Complementary, and the right next step for the "healthy but unreachable" class. It does not replace testing the rules themselves.

## Consequences

**Positive**
- A rule that cannot fire, or fires on everything, fails the build.
- The detection-time claim in the README is a measurement with a method attached.
- Upgrading Prometheus across a major version was verified by running the rule tests against the new binary first.

**Negative**
- Rule tests must be kept in step with annotations: `promtool` compares the rendered text exactly, so rewording a description fails a test. That is friction, and it is also a reminder that alert text is part of the interface.
- More CI time (two short container runs).

## What this does not cover

- The tests prove the rules do what they say. They do not prove the thresholds are the right ones for real traffic; only operating the system does.
- Nothing yet alerts on log shipping stopping, or on a step change in the 4xx ratio. Both are known gaps.

## The Interview Answer

"I reviewed my own monitoring and found eight things that could never have worked, including alert rules that divided a series by itself. None had ever produced an error, because a broken monitor is silent: it looks the same as a healthy system. So I started treating the monitoring as code with its own tests. Alert rules are unit-tested with promtool, including that a 2% error rate fires nothing; detection time is measured stage by stage rather than quoted; and the chaos scenarios say exactly what each one proves. The check I trust most is the boring one: pending to firing takes exactly the rule's `for:` duration, every run."
