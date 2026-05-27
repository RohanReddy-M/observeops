import json
import os
import logging
import urllib.request
import urllib.error
from datetime import datetime, timezone

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

RAGSERVICE_URL = os.environ.get("RAGSERVICE_URL", "https://secureship.click/ai/query")
NOTIFICATION_TOPIC_ARN = os.environ.get("NOTIFICATION_TOPIC_ARN", "")


def query_ragservice(question: str) -> str:
    payload = json.dumps({"question": question}).encode()
    req = urllib.request.Request(
        RAGSERVICE_URL,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST"
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read()).get("answer", "No answer returned")
    except urllib.error.URLError as e:
        logger.error(json.dumps({"event": "ragservice_error", "error": str(e)}))
        return f"RAGService unreachable: {e}"


def publish_to_sns(message: str, subject: str):
    if not NOTIFICATION_TOPIC_ARN:
        return
    boto3.client("sns").publish(
        TopicArn=NOTIFICATION_TOPIC_ARN,
        Message=message,
        Subject=subject[:100]
    )


def analyze_alerts(alerts: list) -> list:
    results = []
    for alert in alerts:
        name = alert.get("labels", {}).get("alertname", "unknown")
        status = alert.get("status", "unknown")
        severity = alert.get("labels", {}).get("severity", "unknown")
        summary = alert.get("annotations", {}).get("summary", "")
        instance = alert.get("labels", {}).get("instance", "")

        logger.info(json.dumps({
            "event": "alert_received",
            "alert": name,
            "status": status,
            "severity": severity
        }))

        question = (
            f"Alert '{name}' is {status} (severity: {severity}). "
            f"{summary}. Instance: {instance}. "
            f"What is the likely cause and how do I resolve it?"
        )
        analysis = query_ragservice(question)

        logger.info(json.dumps({
            "event": "analysis_complete",
            "alert": name,
            "analysis_chars": len(analysis)
        }))

        results.append({
            "alert": name,
            "status": status,
            "severity": severity,
            "analysis": analysis,
            "timestamp": datetime.now(timezone.utc).isoformat()
        })

    return results


def lambda_handler(event, context):
    # EventBridge scheduled health check
    if event.get("source") == "aws.events":
        logger.info(json.dumps({"event": "scheduled_health_check"}))
        analysis = query_ragservice(
            "Run a health check on the ObserveOps platform. "
            "What are the most common issues and what should I verify first?"
        )
        result = {
            "event": "health_check",
            "analysis": analysis,
            "timestamp": datetime.now(timezone.utc).isoformat()
        }
        logger.info(json.dumps(result))
        return {"statusCode": 200, "body": json.dumps(result)}

    # AlertManager webhook via Lambda Function URL
    body = event.get("body", "{}")
    if isinstance(body, str):
        try:
            body = json.loads(body)
        except json.JSONDecodeError:
            return {"statusCode": 400, "body": "Invalid JSON"}

    alerts = body.get("alerts", [])
    if not alerts:
        return {"statusCode": 200, "body": "No alerts"}

    results = analyze_alerts(alerts)

    if NOTIFICATION_TOPIC_ARN and results:
        summary = "\n\n---\n\n".join(
            f"Alert: {r['alert']} ({r['status']} / {r['severity']})\n{r['analysis']}"
            for r in results
        )
        publish_to_sns(summary, f"ObserveOps: {len(results)} alert(s) need attention")

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(results)
    }
