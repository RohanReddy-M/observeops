"""
LLM Alert Autopilot
===================
Receives AlertManager webhooks. For each firing alert:
  1. Fetches recent deploy history (so LLM knows if this correlates with a deploy)
  2. Queries Loki for recent error logs from the affected service
  3. Sends (alert + deploy context + logs) to Groq LLM for diagnosis
  4. Posts diagnosis + suggested fix to Slack

Also tracks DORA metrics:
  - deployments_total: incremented by deploy.sh via POST /deploy-event
  - alert_mttr_seconds: calculated from AlertManager resolved-alert timestamps

Why deploy context matters:
  The most common root cause of incidents is "someone deployed something recently."
  A raw alert without deploy context forces the on-call to manually check git log.
  With deploy context in the LLM prompt, the diagnosis includes: "This error rate spike
  started 8 minutes after commit abc1234 by Rohan — likely a regression."

Endpoints:
  POST /webhook       — AlertManager firing/resolved webhook receiver
  POST /deploy-event  — Called by deploy.sh to register a deployment
  GET  /health        — Liveness probe
  GET  /metrics       — Prometheus metrics (autopilot + DORA)
"""

from __future__ import annotations

import json
import logging
import os
import time
import urllib.parse
import urllib.request
import urllib.error
from datetime import datetime, timezone
from typing import Any

from fastapi import FastAPI, Request, HTTPException, Response
from fastapi.responses import JSONResponse
from groq import Groq
from prometheus_client import Counter, Histogram, Gauge, generate_latest, CONTENT_TYPE_LATEST
from pydantic import BaseModel

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger(__name__)

app = FastAPI(title="LLM Alert Autopilot", version="2.0.0")

# ─── Config ──────────────────────────────────────────────────────────────────
GROQ_API_KEY  = os.environ["GROQ_API_KEY"]
SLACK_WEBHOOK = os.getenv("SLACK_WEBHOOK_URL", "")
LOKI_URL      = os.getenv("LOKI_URL", "http://loki:3100")
GRAFANA_URL   = os.getenv("GRAFANA_URL", "http://grafana:3000")
GRAFANA_PASS  = os.getenv("GRAFANA_PASSWORD", "observeops123")
LLM_MODEL     = "llama-3.1-8b-instant"
LOG_LINES     = 30
LOKI_LOOKBACK = "5m"
LLM_TIMEOUT   = 15

groq_client = Groq(api_key=GROQ_API_KEY)

# ─── In-memory deploy history (max 10, survives until container restart) ────
# Populated by POST /deploy-event from deploy.sh.
# Used to give the LLM context about recent changes.
_recent_deploys: list[dict] = []

# ─── Prometheus Metrics ───────────────────────────────────────────────────────

# Autopilot operational metrics
alerts_received   = Counter("autopilot_alerts_received_total",   "AlertManager webhooks received",        ["alertname", "status"])
alerts_diagnosed  = Counter("autopilot_alerts_diagnosed_total",  "Alerts successfully diagnosed by LLM",  ["alertname"])
diagnosis_errors  = Counter("autopilot_diagnosis_errors_total",  "Errors during diagnosis",               ["stage"])
diagnosis_latency = Histogram("autopilot_diagnosis_latency_seconds", "End-to-end diagnosis latency",
                              buckets=[0.5, 1, 2, 5, 10, 20, 30])

# DORA metrics
# These give you the language to talk about engineering performance, not just system health.
deployments_total           = Counter("deployments_total", "Total production deployments", ["commit", "status"])
last_deployment_timestamp   = Gauge("last_deployment_timestamp_seconds", "Unix timestamp of the most recent deployment")
alert_mttr_seconds          = Histogram(
    "alert_mttr_seconds",
    "Alert mean time to recovery — time from alert firing to alert resolving",
    ["alertname"],
    buckets=[30, 60, 120, 300, 600, 1800, 3600, 7200],
)


# ─── Deploy event model ───────────────────────────────────────────────────────

class DeployEvent(BaseModel):
    commit: str
    deployer: str = "ci"
    status: str = "success"   # success | rollback | failed
    services: list[str] = []


# ─── Loki log fetching ────────────────────────────────────────────────────────

def _fetch_loki_logs(service: str) -> list[str]:
    """Fetch recent error-level logs from Loki for a service."""
    query = f'{{job="{service}"}} |~ "(?i)(error|exception|traceback|critical|oom|killed)"'
    params = urllib.parse.urlencode({
        "query": query,
        "limit": LOG_LINES,
        "start": f"now-{LOKI_LOOKBACK}",
    })
    url = f"{LOKI_URL}/loki/api/v1/query_range?{params}"
    try:
        req = urllib.request.Request(url, headers={"Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read())
        lines = []
        for stream in data.get("data", {}).get("result", []):
            for _, line in stream.get("values", []):
                lines.append(line)
        return lines[-LOG_LINES:]
    except Exception as exc:
        logger.warning("Loki query failed for service=%s: %s", service, exc)
        return []


# ─── Deploy context ───────────────────────────────────────────────────────────

def _build_deploy_context() -> str:
    """
    Return a plain-text summary of recent deployments for the LLM prompt.
    Includes: commit SHA, deployer, time elapsed, and deploy status.
    This is the key insight that lets the LLM say "this alert started 8 minutes
    after commit abc1234 was deployed by Rohan."
    """
    if not _recent_deploys:
        return "(no deployments recorded since autopilot started)"

    now = time.time()
    lines = []
    for d in _recent_deploys[:5]:
        elapsed = int(now - d.get("timestamp_unix", now))
        if elapsed < 60:
            when = f"{elapsed}s ago"
        elif elapsed < 3600:
            when = f"{elapsed // 60}m ago"
        else:
            when = f"{elapsed // 3600}h ago"

        line = (
            f"- commit {d['commit'][:12]} by {d['deployer']} "
            f"({when}, status={d['status']})"
        )
        if d.get("services"):
            line += f" services={','.join(d['services'])}"
        lines.append(line)

    return "\n".join(lines)


def _service_from_alert(labels: dict) -> str:
    return labels.get("job") or labels.get("service") or labels.get("alertname", "unknown")


# ─── LLM Diagnosis ────────────────────────────────────────────────────────────

SYSTEM_PROMPT = """You are an SRE on-call assistant for ObserveOps.
You receive an alert, recent deployment history, and recent error logs.

Your job: diagnose the ROOT CAUSE in 2-3 sentences, then give ONE specific shell command.

Rules:
- Check the deploy history first. If an alert started after a recent deploy, say so explicitly.
- Reference actual log content if present (OOM kill = exit code 137, specific exceptions, etc.)
- The fix command must work with Docker Compose on EC2 (not Kubernetes, not systemctl).
- Prefer investigation commands over restart commands — find the cause before fixing it.
- If logs are empty, explain the most likely cause from the alert metadata.

Format exactly as:
DIAGNOSIS: <2-3 sentence root cause, including deploy correlation if relevant>
FIX: <one shell command>
"""


def _diagnose(alertname: str, labels: dict, annotations: dict,
              log_lines: list[str], deploy_context: str) -> str:
    log_block = "\n".join(log_lines) if log_lines else "(no recent error logs found in Loki)"

    user_content = f"""ALERT: {alertname}
Severity: {labels.get('severity', 'unknown')}
Summary: {annotations.get('summary', 'N/A')}
Description: {annotations.get('description', 'N/A')}

RECENT DEPLOYMENTS (check if alert correlates with a deploy):
{deploy_context}

RECENT ERROR LOGS from Loki ({len(log_lines)} lines):
{log_block}
"""
    response = groq_client.chat.completions.create(
        model=LLM_MODEL,
        messages=[
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user",   "content": user_content},
        ],
        temperature=0,
        max_tokens=350,
        timeout=LLM_TIMEOUT,
    )
    return response.choices[0].message.content.strip()


# ─── Slack notification ───────────────────────────────────────────────────────

_SEVERITY_COLOR = {"critical": "danger", "warning": "warning"}


def _send_slack(alertname: str, severity: str, diagnosis: str,
                log_count: int, deploy_context: str):
    if not SLACK_WEBHOOK:
        return

    diag_line = fix_line = ""
    for line in diagnosis.splitlines():
        if line.startswith("DIAGNOSIS:"):
            diag_line = line.replace("DIAGNOSIS:", "").strip()
        elif line.startswith("FIX:"):
            fix_line = line.replace("FIX:", "").strip()

    color = _SEVERITY_COLOR.get(severity, "#439FE0")
    emoji = "🚨" if severity == "critical" else "⚠️"

    fields = [
        {"title": "Root Cause",      "value": diag_line or diagnosis, "short": False},
        {"title": "Suggested Fix",   "value": f"`{fix_line}`" if fix_line else "—", "short": False},
        {"title": "Recent Deploys",  "value": deploy_context or "—",  "short": False},
        {"title": "Log Lines",       "value": str(log_count),         "short": True},
        {"title": "Severity",        "value": severity,               "short": True},
    ]

    payload = {
        "attachments": [{
            "color": color,
            "title": f"{emoji} AI Diagnosis: {alertname}",
            "fields": fields,
            "footer": "ObserveOps LLM Alert Autopilot  |  Groq llama-3.1-8b-instant",
        }]
    }
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        SLACK_WEBHOOK,
        data=data,
        headers={"Content-Type": "application/json"},
    )
    urllib.request.urlopen(req, timeout=10)


# ─── MTTR calculation ─────────────────────────────────────────────────────────

def _record_mttr(alert: dict):
    """
    When AlertManager sends a resolved alert, calculate MTTR from the payload
    timestamps and record it as a Prometheus histogram observation.
    MTTR = endsAt - startsAt in seconds.
    """
    starts_at = alert.get("startsAt", "")
    ends_at   = alert.get("endsAt", "")
    alertname = alert.get("labels", {}).get("alertname", "unknown")

    if not starts_at or not ends_at:
        return
    try:
        # AlertManager timestamps are ISO 8601 with Z suffix
        fmt = "%Y-%m-%dT%H:%M:%S.%fZ"
        start_dt = datetime.strptime(starts_at[:26] + "Z", fmt)
        end_dt   = datetime.strptime(ends_at[:26] + "Z", fmt)
        mttr = (end_dt - start_dt).total_seconds()
        if 0 < mttr < 86400:  # sanity check: between 0 and 24 hours
            alert_mttr_seconds.labels(alertname=alertname).observe(mttr)
            logger.info("MTTR for %s: %.0fs (%.1f minutes)", alertname, mttr, mttr / 60)
    except Exception as exc:
        logger.warning("Could not parse MTTR timestamps: %s", exc)


# ─── Endpoints ────────────────────────────────────────────────────────────────

@app.post("/webhook")
async def webhook(request: Request):
    """
    AlertManager webhook receiver.
    Handles both firing alerts (→ LLM diagnosis) and resolved alerts (→ MTTR tracking).
    """
    try:
        body: dict[str, Any] = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="invalid JSON")

    # Track MTTR for resolved alerts
    for alert in body.get("alerts", []):
        if alert.get("status") == "resolved":
            _record_mttr(alert)
            alerts_received.labels(
                alertname=alert.get("labels", {}).get("alertname", "unknown"),
                status="resolved"
            ).inc()

    # Diagnose firing alerts
    firing_alerts = [a for a in body.get("alerts", []) if a.get("status") == "firing"]
    if not firing_alerts:
        return JSONResponse({"status": "ok", "processed": 0})

    deploy_context = _build_deploy_context()
    processed = 0

    for alert in firing_alerts:
        labels      = alert.get("labels", {})
        annotations = alert.get("annotations", {})
        alertname   = labels.get("alertname", "UnknownAlert")

        alerts_received.labels(alertname=alertname, status="firing").inc()
        logger.info("Processing firing alert: %s", alertname)

        start = time.time()
        try:
            service   = _service_from_alert(labels)
            log_lines = _fetch_loki_logs(service)
            diagnosis = _diagnose(alertname, labels, annotations, log_lines, deploy_context)

            logger.info("Diagnosis for %s: %s", alertname, diagnosis[:150])
            _send_slack(alertname, labels.get("severity", "warning"),
                        diagnosis, len(log_lines), deploy_context)

            alerts_diagnosed.labels(alertname=alertname).inc()
            processed += 1

        except Exception as exc:
            diagnosis_errors.labels(stage=type(exc).__name__).inc()
            logger.error("Diagnosis failed for %s: %s", alertname, exc, exc_info=True)
        finally:
            diagnosis_latency.observe(time.time() - start)

    return JSONResponse({"status": "ok", "processed": processed})


@app.post("/deploy-event")
async def deploy_event(event: DeployEvent):
    """
    Called by deploy.sh after every production deployment.
    Stores the deploy for LLM context and increments the DORA deployment counter.

    Why this endpoint exists:
    When an alert fires 10 minutes after a deploy, the LLM should automatically
    say "this started after commit X was deployed." Without this, the on-call
    has to manually correlate alert time with git log — wasting minutes during an incident.
    """
    record = {
        "commit":         event.commit,
        "deployer":       event.deployer,
        "status":         event.status,
        "services":       event.services,
        "timestamp_unix": time.time(),
        "timestamp_iso":  datetime.now(timezone.utc).isoformat(),
    }
    _recent_deploys.insert(0, record)
    del _recent_deploys[10:]  # keep last 10

    deployments_total.labels(commit=event.commit[:12], status=event.status).inc()
    last_deployment_timestamp.set(time.time())

    logger.info("Deploy recorded: commit=%s deployer=%s status=%s",
                event.commit[:12], event.deployer, event.status)

    return {
        "status":    "recorded",
        "commit":    event.commit[:12],
        "deployer":  event.deployer,
        "timestamp": record["timestamp_iso"],
    }


@app.get("/deploy-history")
def deploy_history():
    """Returns recent deployment history (used by LLM context + debugging)."""
    return {"deploys": _recent_deploys, "count": len(_recent_deploys)}


@app.get("/health")
def health():
    return {
        "status":            "ok",
        "service":           "llm-alert-autopilot",
        "recent_deploys":    len(_recent_deploys),
        "groq_model":        LLM_MODEL,
    }


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
