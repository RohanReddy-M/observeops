# ADR-006: Prometheus + Grafana Instead of Managed Monitoring (Datadog/New Relic)

**Status:** Accepted
**Date:** 2026-05-01

> **Amended 2026-10-07.** The decision stands. Corrected: the cost figures (the
> stack is about $0.15 an hour while up, not "$12 a month", and vendor prices were
> quoted from memory); retention is 35 days, not 15; the stack runs on its own
> t3.small, not "on a t3.micro alongside the application"; pull-based scraping
> was described as service discovery, which it is not; and the text now says what
> is lost if the monitoring instance is lost.

---

## Context

We need observability: metrics collection, visualization, alerting, and log aggregation. Several options exist ranging from fully managed SaaS products to self-hosted open-source stacks.

## Decision

Self-host Prometheus + Grafana + Loki + AlertManager instead of using Datadog, New Relic, or similar managed products.

## Rationale

**The cost argument:**

Managed observability is priced per host, per gigabyte of logs and per traced request, so the bill grows with the system and with how much you choose to look at. For two small hosts that is a modest monthly amount, and a real one for a stack that otherwise costs about $0.15 an hour and only while it is up. (No vendor price is quoted here on purpose: list prices change, and a number that is wrong in an interview is worse than no number. Check the current pricing page before using one.)

The larger point is not this project's bill. At hundreds of hosts and heavy log volume the managed bill becomes one of a company's biggest infrastructure costs, and being able to build, operate and reason about the self-hosted equivalent is what makes the build-versus-buy conversation a real choice.

**The control argument:**

With managed monitoring, your data lives on someone else's infrastructure. For regulated industries (banking, healthcare, government), this creates compliance issues — you cannot guarantee where your logs are stored or who can access them. Self-hosted Prometheus + Loki means data stays in your VPC.

**The learning argument:**

Running Prometheus, Grafana, and Loki yourself means understanding exactly how metrics collection, time-series storage, and log aggregation work. An engineer who understands PromQL and LogQL at depth can debug observability problems that someone who just clicks around Datadog dashboards cannot. The friction is the feature.

**Why Prometheus specifically over InfluxDB or VictoriaMetrics:**

Prometheus uses the pull model (scrapes targets) rather than push. For our architecture:
- Pull gives a liveness signal for free: Prometheus records `up` for every target on every scrape, so a target that stops answering shows as `up == 0` within one scrape interval (15 s) without the target doing anything. (This is not service discovery. Targets here are a static list; discovering them dynamically is a separate Prometheus feature that this project does not need with two hosts.)
- The alert rule `up == 0` is trivial to write. In a push model you'd need heartbeat timeouts and more complex alerting logic.
- The entire Kubernetes ecosystem uses Prometheus as the de-facto standard. The same skills apply whether you're monitoring Docker Compose services locally or 500 Kubernetes pods.
- PromQL has a learning curve but is far more expressive than InfluxQL for the time-series operations observability needs (rates, quantiles, joins)

**Why Loki over Elasticsearch:**

Elasticsearch indexes every field in every log line. This is powerful for ad-hoc search but expensive in memory and storage. A single Elasticsearch node on a t3.micro would consume all available RAM.

Loki uses label-based indexing (only the labels you define, like `job`, `service`, `level`). It stores log content compressed without full-text indexing. For our access pattern — "show me logs from service X in the last 5 minutes" — Loki is orders of magnitude cheaper to run.

The tradeoff: Loki cannot do arbitrary field-level search without LogQL's `|=` filter and `| json` parser operations. We accept this because our access pattern is time-bounded + service-bounded, not arbitrary search.

**Why AlertManager over PagerDuty:**

AlertManager handles what this project needs from an alert pipeline: routing, grouping, inhibition and webhook receivers. The LLM Alert Autopilot is an AlertManager webhook receiver. What AlertManager does not do is the thing PagerDuty is actually for: on-call schedules, escalation when nobody acknowledges, and phone calls. With one person on call there is no rota to manage. In a team, the usual arrangement is both: AlertManager decides what is worth a notification and PagerDuty decides who is woken.

## Consequences

**Positive:**
- Zero licensing cost
- Data stays in our VPC
- Full control over retention, alerting logic, and dashboard design
- Runs on one t3.small (ADR-001), using roughly 500 MB at idle

**Negative:**
- We are responsible for the operational health of our monitoring stack
- HA (high-availability) Prometheus requires Thanos or Cortex (not needed at this scale)
- No built-in anomaly detection or ML-based alerting (Datadog has this)
- Dashboard setup and PromQL require expertise that Datadog abstracts away

**Mitigation:**

The monitoring stack runs on a separate EC2 instance (see ADR-001) so a failure in the application stack doesn't take down monitoring. Prometheus keeps 35 days of data on a named Docker volume: 35 because the SLO window is 30 days, and a retention shorter than the window makes the error budget unanswerable. If the monitoring instance is lost, `terraform apply` rebuilds it in about ten minutes, with EMPTY history: the volume lives on the instance's disk and nothing copies it elsewhere. Metrics history, logs and traces do not survive the instance. That is acceptable for a stack that is torn down between uses and would not be for one that is kept.

## When this decision would change

At 50+ services or 10+ engineers, the operational burden of self-hosted monitoring starts to compete with the cost savings. The migration path is Grafana Cloud (managed Grafana + Prometheus + Loki), which maintains PromQL/LogQL compatibility while eliminating operations overhead. Our dashboards and alert rules would migrate unchanged.

## The Interview Answer

"We chose self-hosted Prometheus + Grafana + Loki over Datadog because a per-host, per-gigabyte bill is out of proportion for two small hosts that only run for demonstrations. But the more important reason is understanding: running the stack yourself means you know why `histogram_quantile` is an estimate whose accuracy depends on bucket boundaries, why Loki indexes labels and not log text, and what AlertManager's grouping and inhibition do to a notification. An engineer who understands those things can debug observability problems in any system, not just the ones with Datadog already installed. When the bill does justify Datadog, we'd migrate — our dashboards and PromQL expressions port directly to Grafana Cloud."
