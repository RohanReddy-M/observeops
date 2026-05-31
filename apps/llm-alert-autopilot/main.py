"""
LLM Alert Autopilot
===================
Receives AlertManager webhooks.
For each firing alert:
  1. Queries Loki for recent error logs from the affected service.
  2. Sends (alert metadata + log lines) to Groq LLM for diagnosis.
  3. Posts the diagnosis to Slack with the suggested fix command.

Exposed endpoints:
  POST /webhook  — AlertManager webhook receiver
  GET  /health   — liveness probe
  GET  /metrics  — Prometheus metrics
"""

from __future__ import annotations

import json
import logging
import os
import time
import urllib.parse
import urllib.request
import urllib.error
from typing import Any

from fastapi import FastAPI, Request, HTTPException, Response
from fastapi.responses import JSONResponse
from groq import Groq
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger(__name__)

app = FastAPI(title="LLM Alert Autopilot", version="1.0.0")

# ─── Config ──────────────────────────────────────────────────────────────────
GROQ_API_KEY     = os.environ["GROQ_API_KEY"]
SLACK_WEBHOOK    = os.getenv("SLACK_WEBHOOK_URL", "")
LOKI_URL         = os.getenv("LOKI_URL", "http://loki:3100")
LLM_MODEL        = "llama-3.1-8b-instant"
LOG_LINES        = 30       # how many recent log lines to fetch per alert
LOKI_LOOKBACK    = "5m"     # how far back to search for logs
LLM_TIMEOUT      = 15       # seconds

groq_client = Groq(api_key=GROQ_API_KEY)

# ─── Prometheus Metrics ───────────────────────────────────────────────────────
alerts_received   = Counter("autopilot_alerts_received_total",   "Total AlertManager webhooks received",   ["alertname"])
alerts_diagnosed  = Counter("autopilot_alerts_diagnosed_total",  "Alerts successfully diagnosed by LLM",   ["alertname"])
diagnosis_errors  = Counter("autopilot_diagnosis_errors_total",  "Errors during diagnosis",                ["stage"])
diagnosis_latency = Histogram("autopilot_diagnosis_latency_seconds", "End-to-end diagnosis latency",
                              buckets=[0.5, 1, 2, 5, 10, 20, 30])

# ─── Loki helpers ─────────────────────────────────────────────────────────────

def _fetch_loki_logs(service: str) -> list[str]:
    """
    Query Loki for recent error-level logs from a service.
    Returns a list of log line strings (empty list on failure).
    LogQL: {job="<service>"} |~ "(?i)(error|exception|traceback|critical)"
    """
    query = f'{{job="{service}"}} |~ "(?i)(error|exception|traceback|critical)"'
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


def _service_from_alert(labels: dict) -> str:
    """
    Derive the Loki job name from alert labels.
    AlertManager label 'job' matches the Prometheus job_name, which matches
    the Promtail service label we set in promtail-config.yml.
    Falls back to 'alertname' value if 'job' is absent.
    """
    return labels.get("job") or labels.get("service") or labels.get("alertname", "unknown")


# ─── LLM Diagnosis ────────────────────────────────────────────────────────────

SYSTEM_PROMPT = """You are an SRE on-call assistant for ObserveOps.
You will receive an alert and recent error logs from the affected service.
Your job is to diagnose the root cause in 2-3 sentences, then give ONE specific
shell command that fixes or investigates it further.

Rules:
- Be specific. Reference actual log content if present.
- The fix command must work with Docker Compose (not Kubernetes).
- If logs are empty, say so and suggest the most likely cause based on the alert.
- Do not pad with generic advice. Be direct.

Format your response exactly as:
DIAGNOSIS: <2-3 sentence root cause>
FIX: <one shell command>
"""

def _diagnose(alertname: str, labels: dict, annotations: dict, log_lines: list[str]) -> str:
    """Call Groq LLM with alert context + logs. Returns 'DIAGNOSIS: ...\nFIX: ...'."""
    log_block = "\n".join(log_lines) if log_lines else "(no recent error logs found)"

    user_content = f"""ALERT: {alertname}
Severity: {labels.get('severity', 'unknown')}
Summary: {annotations.get('summary', 'N/A')}
Description: {annotations.get('description', 'N/A')}

RECENT ERROR LOGS ({len(log_lines)} lines):
{log_block}
"""
    response = groq_client.chat.completions.create(
        model=LLM_MODEL,
        messages=[
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user",   "content": user_content},
        ],
        temperature=0,
        max_tokens=300,
        timeout=LLM_TIMEOUT,
    )
    return response.choices[0].message.content.strip()


# ─── Slack helpers ─────────────────────────────────────────────────────────────

_SEVERITY_COLOR = {"critical": "danger", "warning": "warning"}

def _send_slack(alertname: str, severity: str, diagnosis: str, log_count: int):
    """Post the LLM diagnosis to Slack. No-op if SLACK_WEBHOOK is not set."""
    if not SLACK_WEBHOOK:
        logger.info("SLACK_WEBHOOK_URL not set — skipping Slack notification")
        return

    # Parse 'DIAGNOSIS: ...\nFIX: ...' out of LLM response
    diag_line = fix_line = ""
    for line in diagnosis.splitlines():
        if line.startswith("DIAGNOSIS:"):
            diag_line = line.replace("DIAGNOSIS:", "").strip()
        elif line.startswith("FIX:"):
            fix_line = line.replace("FIX:", "").strip()

    color  = _SEVERITY_COLOR.get(severity, "#439FE0")
    emoji  = "🚨" if severity == "critical" else "⚠️"

    payload = {
        "attachments": [{
            "color": color,
            "title": f"{emoji} AI Diagnosis: {alertname}",
            "fields": [
                {"title": "Root Cause",    "value": diag_line or diagnosis, "short": False},
                {"title": "Suggested Fix", "value": f"`{fix_line}`" if fix_line else "—", "short": False},
                {"title": "Log Lines Used","value": str(log_count),         "short": True},
                {"title": "Severity",      "value": severity,               "short": True},
            ],
            "footer": "ObserveOps LLM Alert Autopilot  |  Groq llama-3.1-8b-instant",
        }]
    }
    data = json.dumps(payload).encode()
    req  = urllib.request.Request(
        SLACK_WEBHOOK,
        data=data,
        headers={"Content-Type": "application/json"},
    )
    urllib.request.urlopen(req, timeout=10)


# ─── Webhook endpoint ──────────────────────────────────────────────────────────

@app.post("/webhook")
async def webhook(request: Request):
    """
    AlertManager webhook receiver.
    Payload: https://prometheus.io/docs/alerting/latest/configuration/#webhook_config
    """
    try:
        body: dict[str, Any] = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="invalid JSON")

    firing_alerts = [a for a in body.get("alerts", []) if a.get("status") == "firing"]
    if not firing_alerts:
        return JSONResponse({"status": "ok", "processed": 0})

    processed = 0
    for alert in firing_alerts:
        labels      = alert.get("labels", {})
        annotations = alert.get("annotations", {})
        alertname   = labels.get("alertname", "UnknownAlert")

        alerts_received.labels(alertname=alertname).inc()
        logger.info("Processing alert: %s labels=%s", alertname, labels)

        start = time.time()
        try:
            service   = _service_from_alert(labels)
            log_lines = _fetch_loki_logs(service)

            diagnosis = _diagnose(alertname, labels, annotations, log_lines)
            logger.info("Diagnosis for %s: %s", alertname, diagnosis[:120])

            _send_slack(alertname, labels.get("severity", "warning"), diagnosis, len(log_lines))

            alerts_diagnosed.labels(alertname=alertname).inc()
            processed += 1

        except Exception as exc:
            stage = type(exc).__name__
            diagnosis_errors.labels(stage=stage).inc()
            logger.error("Diagnosis failed for %s: %s", alertname, exc, exc_info=True)
        finally:
            diagnosis_latency.observe(time.time() - start)

    return JSONResponse({"status": "ok", "processed": processed})


# ─── Health + Metrics ─────────────────────────────────────────────────────────

@app.get("/health")
def health():
    return {"status": "ok", "service": "llm-alert-autopilot"}


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
