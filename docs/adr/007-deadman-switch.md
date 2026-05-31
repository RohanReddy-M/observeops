# ADR-007: Deadman Switch for the Alerting Pipeline

**Status:** Accepted
**Date:** 2026-05-01

---

## Context

We have a comprehensive alerting system: Prometheus fires alerts, AlertManager routes them to Slack and the LLM Autopilot. But there is a fundamental gap: **who monitors the monitoring system?**

If Prometheus crashes, no alerts fire. If AlertManager crashes, alerts fire but go nowhere. If the network between them breaks, the same result. In all three cases — complete silence. An on-call engineer assumes everything is fine because there are no alerts, when in reality the entire alerting pipeline is dead.

This is not a hypothetical. It is the most common reason monitoring fails in production.

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
| Prometheus crashes | Silence — no alerts fire | External alert within 10 minutes |
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

**Just monitor Prometheus with another Prometheus:** The second Prometheus becomes the same problem one level up. You cannot use a system to monitor itself reliably.

**Uptime monitoring on the Grafana URL:** This checks that Grafana is serving the UI, not that Prometheus is evaluating rules. Two different things.

**CloudWatch Alarms on EC2 (AWS-native):** Valid option. We'd set an alarm on `StatusCheckFailed` for the obs EC2. This catches EC2 health issues but not Prometheus-specific failures (like a misconfigured rules file that silently breaks all alerts).

The Watchdog approach is the standard recommended by the Prometheus project. It is the only method that verifies the complete Prometheus → AlertManager → notification path.

## The Interview Answer

"One problem most monitoring setups miss: how do you know your monitoring is working? If Prometheus dies, you get no alerts — including the alert that Prometheus died. We solve this with a deadman switch. The Watchdog alert fires every 15 seconds via `vector(1)`. AlertManager routes it to healthchecks.io. If healthchecks.io stops receiving pings, it emails us within 10 minutes. The pipeline has to actively maintain the heartbeat — if it fails, the external system raises the alarm. This is the standard pattern from the Prometheus project. Without it, your monitoring can be completely broken and you won't know until a real incident goes undetected."
