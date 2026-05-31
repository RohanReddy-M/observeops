"""
Audit Alerter Lambda
====================
Triggered by EventBridge when CloudTrail records a dangerous AWS API call.
Formats the event into a human-readable Slack message:
  who did it, what they did, when, from which IP.

No external dependencies — uses only stdlib + boto3 (pre-installed in Lambda).
"""

import json
import logging
import os
import urllib.request
import urllib.error

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

_ssm = None


def get_ssm():
    global _ssm
    if _ssm is None:
        _ssm = boto3.client("ssm", region_name=os.environ.get("AWS_REGION", "ap-south-1"))
    return _ssm


def get_slack_webhook() -> str:
    param = get_ssm().get_parameter(
        Name="/observeops/production/slack_webhook_critical",
        WithDecryption=True,
    )
    return param["Parameter"]["Value"]


# Map CloudTrail eventName → (human description, emoji, color)
WATCHED_EVENTS = {
    # ── Database ──────────────────────────────────────────────────────────────
    "DeleteTable":               ("DynamoDB table deleted",           "🗄️",  "danger"),
    # ── Compute ───────────────────────────────────────────────────────────────
    "TerminateInstances":        ("EC2 instances terminated",         "🖥️",  "danger"),
    "StopInstances":             ("EC2 instances stopped",            "🖥️",  "warning"),
    "RunInstances":              ("New EC2 instances launched",        "🚀",  "warning"),
    # ── Networking / Security groups ──────────────────────────────────────────
    "DeleteSecurityGroup":       ("Security group deleted",           "🔒",  "danger"),
    "AuthorizeSecurityGroupIngress": ("Inbound firewall rule added — new port exposed", "🔓", "warning"),
    "RevokeSecurityGroupIngress": ("Inbound firewall rule removed",   "🔒",  "good"),
    # ── IAM ───────────────────────────────────────────────────────────────────
    "CreateAccessKey":           ("IAM access key created — verify this was intentional", "🔑", "danger"),
    "DeleteAccessKey":           ("IAM access key deleted",           "🔑",  "warning"),
    "AttachUserPolicy":          ("Policy attached to IAM user — permission escalation risk", "👤", "danger"),
    "AttachRolePolicy":          ("Policy attached to IAM role",      "👤",  "warning"),
    "DetachRolePolicy":          ("Policy detached from IAM role",    "👤",  "warning"),
    "CreateRole":                ("New IAM role created",             "👤",  "warning"),
    # ── Storage ───────────────────────────────────────────────────────────────
    "DeleteBucket":              ("S3 bucket deleted",                "🪣",  "danger"),
    "PutBucketPolicy":           ("S3 bucket policy changed",         "🪣",  "warning"),
}


def extract_resource(event_name: str, request_params: dict) -> str:
    """Pull the most relevant resource identifier from request parameters."""
    if not request_params:
        return ""
    checks = [
        ("tableName",    "Table"),
        ("bucketName",   "Bucket"),
        ("roleName",     "Role"),
        ("userName",     "User"),
        ("groupId",      "Security Group"),
        ("groupName",    "Security Group"),
        ("policyArn",    "Policy"),
    ]
    for key, label in checks:
        if key in request_params:
            return f"{label}: `{request_params[key]}`"

    # EC2 instances need special handling
    if "instancesSet" in request_params:
        items = request_params["instancesSet"].get("items", [])
        ids = [i.get("instanceId", "") for i in items if i.get("instanceId")]
        if ids:
            return f"Instances: `{', '.join(ids)}`"

    return ""


def lambda_handler(event, context):
    logger.info("Received CloudTrail event: %s", json.dumps(event, default=str))

    detail = event.get("detail", {})
    event_name = detail.get("eventName", "Unknown")

    action_info = WATCHED_EVENTS.get(event_name)
    if action_info is None:
        # EventBridge rule should prevent this, but guard anyway
        logger.info("Ignoring unexpected event: %s", event_name)
        return {"statusCode": 200, "body": "ignored"}

    description, emoji, color = action_info

    # ── Extract context ────────────────────────────────────────────────────────
    user_identity   = detail.get("userIdentity", {})
    user_arn        = user_identity.get("arn") or user_identity.get("principalId", "Unknown")
    user_type       = user_identity.get("type", "Unknown")
    source_ip       = detail.get("sourceIPAddress", "Unknown")
    region          = detail.get("awsRegion", "Unknown")
    event_time      = detail.get("eventTime", "Unknown")
    request_params  = detail.get("requestParameters") or {}
    resource        = extract_resource(event_name, request_params)

    # ── Build Slack message ────────────────────────────────────────────────────
    fields = [
        {"title": "Who",            "value": user_arn,   "short": False},
        {"title": "User Type",      "value": user_type,  "short": True},
        {"title": "Source IP",      "value": source_ip,  "short": True},
        {"title": "Region",         "value": region,     "short": True},
        {"title": "Time (UTC)",     "value": event_time, "short": True},
    ]
    if resource:
        fields.append({"title": "Resource", "value": resource, "short": False})

    message = {
        "attachments": [{
            "color":  color,
            "title":  f"{emoji}  AUDIT ALERT: {event_name}",
            "text":   description,
            "fields": fields,
            "footer": "ObserveOps Audit Alert  |  AWS CloudTrail  |  EventBridge",
        }]
    }

    # ── Send to Slack ──────────────────────────────────────────────────────────
    try:
        webhook_url = get_slack_webhook()
        data = json.dumps(message).encode()
        req = urllib.request.Request(
            webhook_url,
            data=data,
            headers={"Content-Type": "application/json"},
        )
        urllib.request.urlopen(req, timeout=10)
        logger.info("Slack alert sent for %s by %s from %s", event_name, user_arn, source_ip)
    except urllib.error.HTTPError as exc:
        logger.error("Slack webhook returned %s: %s", exc.code, exc.read())
        raise
    except Exception as exc:
        logger.error("Failed to send Slack alert: %s", exc)
        raise

    return {"statusCode": 200, "body": f"Alert sent for {event_name}"}
