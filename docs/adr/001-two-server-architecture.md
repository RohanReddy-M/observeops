# ADR-001: Separate EC2 Instances for Application and Observability

**Status:** Accepted
**Date:** 2026-05-01

---

## Context

We needed to deploy a monitoring system alongside the application it monitors. The obvious approach is to run everything on one server. We chose not to.

## Decision

Run the application stack (SecureShip, StatusService, RAGService, nginx) on one EC2 instance and the monitoring stack (Prometheus, Grafana, Loki, AlertManager) on a separate EC2 instance.

## Rationale

**The core problem: you cannot use your monitoring system to diagnose a problem with your monitoring system.**

If the application has a memory leak, CPU spike, or disk pressure — and monitoring is on the same server — the alert that should fire might not fire because the monitoring system is also resource-starved.

This is called the "observability independence" principle. Your monitoring stack must be isolated from what it monitors. Companies like Datadog, New Relic, and PagerDuty run on completely separate infrastructure from their customers' applications for exactly this reason.

**Secondary reasons:**

1. **Security boundary**: The monitoring server has read access to application metrics. If the application server is compromised, the attacker cannot pivot to the monitoring server through the same vector.

2. **Resource isolation**: Prometheus and Loki are memory-hungry at scale (Prometheus stores time-series data, Loki buffers log chunks). On a t3.micro with 1GB RAM, they compete directly with the application workload.

3. **Independent restart**: Rolling out a new version of the application does not affect monitoring continuity. If we ran everything together, a bad deploy could blind our monitoring at exactly the moment we need it most.

## Consequences

**Positive:**
- Monitoring stays up even during application incidents
- Resources dedicated to each concern
- Clear security boundary

**Negative:**
- Two EC2 instances instead of one (~2x base cost)
- Prometheus on the obs server must reach the app server over the network
- More infrastructure to manage

**Alternatives considered:**

*One server:* Simpler and cheaper. Rejected because of the observability independence requirement.

*Managed monitoring (Datadog, New Relic):* Eliminates the problem entirely. Rejected because of cost ($30-100/month) and because running our own stack is the point of the project.

*Kubernetes with resource limits:* Would achieve resource isolation without two servers. Rejected because EKS adds operational complexity and cost that isn't justified at this scale. The K8s manifests exist in the repo for when we do scale.

## The Interview Answer

"We separated app and monitoring onto different EC2 instances because a monitoring system that can be taken down by the problem it's supposed to detect isn't worth having. If the app server has a CPU spike or disk pressure, the obs server is unaffected. The alerts still fire, the dashboards still work, and we can diagnose the problem without losing visibility."
