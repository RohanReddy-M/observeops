# ADR-001: Separate EC2 Instances for Application and Observability

**Status:** Accepted
**Date:** 2026-05-01

> **Amended 2026-10-07.** The decision stands. Three facts were corrected: the
> instances are t3.small (2 GB), not t3.micro; the "security boundary" paragraph
> claimed more than the network and IAM setup delivered (the two servers shared one
> IAM role and the application server accepted all traffic from the VPC until this
> date); and the monitoring server's own death is not covered by this decision at
> all. That needs something outside both servers: see ADR-007 and the outside-in
> probe in the README.

---

## Context

We needed to deploy a monitoring system alongside the application it monitors. The obvious approach is to run everything on one server. We chose not to.

## Decision

Run the application stack (nginx, SecureShip, StatusService, RAGService, the alert autopilot) on one EC2 instance and the monitoring stack (Prometheus, AlertManager, Grafana, Loki, Tempo) on a separate EC2 instance.

## Rationale

**The core problem: you cannot use your monitoring system to diagnose a problem with your monitoring system.**

If the application has a memory leak, CPU spike, or disk pressure — and monitoring is on the same server — the alert that should fire might not fire because the monitoring system is also resource-starved.

The principle: monitoring must not share a failure domain with what it monitors. A failure domain is the set of things one fault takes down together; here that is a host and its memory, CPU and disk.

**Secondary reasons:**

1. **Security boundary**: each server has its own IAM role and its own security group, and the groups admit each other only on named ports. This is weaker than it sounds and should be stated exactly: a compromised application server can still reach Grafana, Prometheus and Loki on the monitoring server, because nginx and the log shipper legitimately do. What it cannot do is use the monitoring server's role, or reach anything on it that is not one of those ports.

2. **Resource isolation**: the application server's largest process is RAGService (an embedding model in memory, about 400 MB); the monitoring server's are Prometheus and Loki. On one 2 GB t3.small they would compete, and the first thing the kernel's out-of-memory killer chose might be the thing that should have reported the problem.

3. **Independent restart**: Rolling out a new version of the application does not affect monitoring continuity. If we ran everything together, a bad deploy could blind our monitoring at exactly the moment we need it most.

## Consequences

**Positive:**
- Monitoring stays up even during application incidents
- Resources dedicated to each concern
- Clear security boundary

**Negative:**
- Two EC2 instances instead of one. Each is still a single point of failure for its own role: this separates the two failure domains, it does not make either one redundant
- Prometheus on the obs server must reach the app server over the network
- More infrastructure to manage

**Alternatives considered:**

*One server:* Simpler and cheaper. Rejected because of the observability independence requirement.

*Managed monitoring (Datadog, New Relic, Grafana Cloud):* Eliminates the problem entirely, because the monitoring then runs on someone else's infrastructure. Rejected because operating the stack is the point of the project (ADR-006).

*Kubernetes with resource limits:* Would achieve resource isolation without two servers. Rejected because EKS adds operational complexity and cost that isn't justified at this scale. The K8s manifests exist in the repo for when we do scale.

## The Interview Answer

"We separated app and monitoring onto different EC2 instances because a monitoring system that can be taken down by the problem it's supposed to detect isn't worth having. If the app server has a CPU spike or disk pressure, the obs server is unaffected. The alerts still fire, the dashboards still work, and we can diagnose the problem without losing visibility."
