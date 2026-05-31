# ADR-006: Prometheus + Grafana Instead of Managed Monitoring (Datadog/New Relic)

**Status:** Accepted
**Date:** 2026-05-01

---

## Context

We need observability: metrics collection, visualization, alerting, and log aggregation. Several options exist ranging from fully managed SaaS products to self-hosted open-source stacks.

## Decision

Self-host Prometheus + Grafana + Loki + AlertManager instead of using Datadog, New Relic, or similar managed products.

## Rationale

**The cost argument:**

Datadog pricing at our scale: ~$15/host/month for infrastructure monitoring, ~$2.50/million log events ingested, ~$2.50/million APM spans. For ObserveOps with 3-5 services and moderate traffic, this is ~$50-100/month minimum. Our entire AWS bill is ~$12/month. Monitoring shouldn't cost more than the infrastructure.

At scale (100 hosts, 1TB logs/day), Datadog costs $50K-$200K/year. Companies routinely switch from Datadog to self-hosted at the point where the bill becomes a line item in board meetings. Understanding how to build and operate a self-hosted stack is a skill that saves companies real money.

**The control argument:**

With managed monitoring, your data lives on someone else's infrastructure. For regulated industries (banking, healthcare, government), this creates compliance issues — you cannot guarantee where your logs are stored or who can access them. Self-hosted Prometheus + Loki means data stays in your VPC.

**The learning argument:**

Running Prometheus, Grafana, and Loki yourself means understanding exactly how metrics collection, time-series storage, and log aggregation work. An engineer who understands PromQL and LogQL at depth can debug observability problems that someone who just clicks around Datadog dashboards cannot. The friction is the feature.

**Why Prometheus specifically over InfluxDB or VictoriaMetrics:**

Prometheus uses the pull model (scrapes targets) rather than push. For our architecture:
- Pull model gives us automatic service discovery — if a container stops responding, Prometheus knows immediately (`up == 0`)
- The alert rule `up == 0` is trivial to write. In a push model you'd need heartbeat timeouts and more complex alerting logic.
- The entire Kubernetes ecosystem uses Prometheus as the de-facto standard. The same skills apply whether you're monitoring Docker Compose services locally or 500 Kubernetes pods.
- PromQL has a learning curve but is far more expressive than InfluxQL for the time-series operations observability needs (rates, quantiles, joins)

**Why Loki over Elasticsearch:**

Elasticsearch indexes every field in every log line. This is powerful for ad-hoc search but expensive in memory and storage. A single Elasticsearch node on a t3.micro would consume all available RAM.

Loki uses label-based indexing (only the labels you define, like `job`, `service`, `level`). It stores log content compressed without full-text indexing. For our access pattern — "show me logs from service X in the last 5 minutes" — Loki is orders of magnitude cheaper to run.

The tradeoff: Loki cannot do arbitrary field-level search without LogQL's `|=` filter and `| json` parser operations. We accept this because our access pattern is time-bounded + service-bounded, not arbitrary search.

**Why AlertManager over PagerDuty:**

PagerDuty adds ~$20/user/month. AlertManager is free and handles everything we need: routing, grouping, inhibition rules, and webhook receivers. The LLM Alert Autopilot we built is a custom AlertManager webhook receiver — we couldn't build that on top of PagerDuty without their API.

## Consequences

**Positive:**
- Zero licensing cost
- Data stays in our VPC
- Full control over retention, alerting logic, and dashboard design
- The stack runs on a t3.micro alongside the application — no additional servers

**Negative:**
- We are responsible for the operational health of our monitoring stack
- HA (high-availability) Prometheus requires Thanos or Cortex (not needed at this scale)
- No built-in anomaly detection or ML-based alerting (Datadog has this)
- Dashboard setup and PromQL require expertise that Datadog abstracts away

**Mitigation:**

The monitoring stack runs on a separate EC2 instance (see ADR-001) so a failure in the application stack doesn't take down monitoring. Prometheus data is persisted to a named Docker volume with 15-day retention. If the monitoring instance fails, we can restore from a terraform apply in ~5 minutes with a fresh Prometheus instance.

## When this decision would change

At 50+ services or 10+ engineers, the operational burden of self-hosted monitoring starts to compete with the cost savings. The migration path is Grafana Cloud (managed Grafana + Prometheus + Loki), which maintains PromQL/LogQL compatibility while eliminating operations overhead. Our dashboards and alert rules would migrate unchanged.

## The Interview Answer

"We chose self-hosted Prometheus + Grafana + Loki over Datadog because our entire AWS bill is $12/month — monitoring can't cost $100/month. But the more important reason is operational understanding: running the monitoring stack yourself means you know exactly why `histogram_quantile` is expensive, why Loki uses label-based indexing instead of full-text, and why AlertManager's inhibition rules matter. An engineer who understands those things can debug observability problems in any system, not just the ones with Datadog already installed. When the bill does justify Datadog, we'd migrate — our dashboards and PromQL expressions port directly to Grafana Cloud."
