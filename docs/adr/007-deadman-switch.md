# ADR-007: Deadman Switch for the Alerting Pipeline

**Status:** Accepted. The in-stack half is implemented and tested; the external half needs one parameter that only the owner can create (see "Implementation status").
**Date:** 2026-05-01

> **Amended 2026-10-07.** Until this date the `Watchdog` alert was routed to a
> receiver with no destination, so the switch described here did not exist: it
> fired and went nowhere. See "Implementation status" at the end.

---

## Context

We have a comprehensive alerting system: Prometheus fires alerts, AlertManager routes them to Slack and the LLM Autopilot. But there is a fundamental gap: **who monitors the monitoring system?**

If Prometheus crashes, no alerts fire. If AlertManager crashes, alerts fire but go nowhere. If the network between them breaks, the same result. In all three cases — complete silence. An on-call engineer assumes everything is fine because there are no alerts, when in reality the entire alerting pipeline is dead.

A dead alerting pipeline and a healthy system look identical from the outside: both are silent.

## Decision

Implement a **Watchdog alert** as a deadman switch:

1. Prometheus continuously evaluates `vector(1)` — an expression that is always true
2. This fires a `Watchdog` alert every evaluation cycle (every 15 seconds)
3. AlertManager routes `Watchdog` to a dedicated `watchdog-sink` receiver
4. The `watchdog-sink` pings healthchecks.io every 5 minutes
5. healthchecks.io expects a ping. If it doesn't receive one for 10 minutes, it sends an alert via email or Slack

The name "deadman switch" comes from railway brakes: the engineer must actively hold a lever for the train to move. Release it (go unconscious, have a heart attack) and the train automatically stops. Our alerting pipeline must actively "hold" the switch — if it fails, the external service raises the alarm.

## How It Works

```
Prometheus evaluates `vector(1)` every 15s
    ↓  always fires
AlertManager receives Watchdog every 15s
    ↓  routes to watchdog-sink
watchdog-sink pings healthchecks.io every 5m
    ↓  if pings stop
healthchecks.io emails/Slacks: "ObserveOps alerting pipeline is DOWN"
```

**Why pings every 5 minutes instead of every 15 seconds?**

AlertManager's `repeat_interval: 5m` controls how often it resends an ongoing alert. The Watchdog alert fires every 15s but AlertManager only re-notifies every 5 minutes. healthchecks.io has a 10-minute grace period before alerting, so if one ping is missed (transient network issue) we don't get a false alarm.

## What This Catches

| Failure | Without deadman switch | With deadman switch |
|---------|------------------------|---------------------|
| Prometheus crashes | Silence — no alerts fire | External alert after the monitor's period plus grace (5 + 10 minutes as configured) |
| AlertManager crashes | Alerts fire, go nowhere | External alert within 10 minutes |
| Obs server reboots | Silence for full reboot time | External alert within 10 minutes |
| Network partition | Silence | External alert within 10 minutes |
| Someone accidentally stops Docker | Silence | External alert within 10 minutes |

## What It Does NOT Catch

The Watchdog proves the pipeline between Prometheus and healthchecks.io is alive. It does NOT prove:
- That individual alert rules are correctly written (a badly written rule never fires)
- That Slack is receiving messages (Slack could be down, we'd see the pings still going)
- That the LLM Autopilot is working (it could be crashing silently on every alert)

This is why we also run chaos experiments — they verify the end-to-end system, not just the pipeline.

## Alternatives Considered

**Monitor Prometheus with another Prometheus:** Common and useful when there are several (they watch each other), but the chain has to end somewhere outside the systems being watched, and with a single monitoring host there is nowhere inside to end it.

**Uptime monitoring on the Grafana URL:** This checks that Grafana is serving the UI, not that Prometheus is evaluating rules. Two different things.

**CloudWatch Alarms on EC2 (AWS-native):** Valid option. We'd set an alarm on `StatusCheckFailed` for the obs EC2. This catches EC2 health issues but not Prometheus-specific failures (like a misconfigured rules file that silently breaks all alerts).

An always-firing `Watchdog` alert routed to an external heartbeat is the pattern used by the widely deployed kube-prometheus rule set. Its strength is that it exercises the real path, rule evaluation to AlertManager to an outbound notification, on every cycle.

## Implementation status

| Part | State |
|---|---|
| `Watchdog` rule, always firing | In `alerts.yml`, covered by a `promtool` unit test |
| Route to `watchdog-sink` only, every 5 minutes | In `alertmanager.yml`, asserted in CI with `amtool config routes test` |
| Ping URL | Read from a file that the server's boot script writes from SSM parameter `/observeops/production/healthchecks_url` |
| The external monitor itself | **Exists only if that parameter has been created.** Without it AlertManager logs a failed notification every 5 minutes, on purpose: a deadman switch connected to nothing should not be quiet about it |

There is also a second, independent outside view that needs no setup: a Lambda outside the VPC requests the public URL every five minutes and posts to Slack if it cannot (`apps/lambda/external_probe`). The two cover different failures. The probe catches "users cannot reach the site" whatever the cause; the deadman switch catches "the alerting pipeline has stopped", which the probe cannot see as long as the site still answers.

## The Interview Answer

"If Prometheus dies you get no alerts, including the one saying Prometheus died, and silence looks exactly like health. So the pipeline has to prove it is alive: an alert that always fires is routed to an external heartbeat monitor every five minutes, and that monitor raises the alarm when the pings stop. I should be precise about my own setup: when I reviewed it, the always-firing alert was routed to a receiver with no destination, so the switch was drawn but not wired. I fixed the routing and added a test for it. The last step, the external monitor's URL, is a secret the stack reads from Parameter Store, and until it is there AlertManager logs a failure every five minutes so that the gap is visible."
