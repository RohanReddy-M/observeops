"""
Outside-in probe
================
Runs every five minutes, OUTSIDE the VPC, and asks the only question a user
cares about: does the public URL answer?

Everything else in this project watches from the inside. Prometheus scrapes the
services over private addresses, so it can report every service healthy while
the load balancer, a security group or DNS is keeping every real user out. And
if the monitoring host itself dies, it reports nothing at all. This probe takes
the same path a browser takes (internet -> load balancer -> nginx -> service),
so it fails when users fail, whatever the reason.

It is deliberately small and stateless:
  - standard library only (boto3 ships with the Lambda runtime)
  - one retry after a pause, so the few seconds nginx is recreated during a
    deploy do not page anyone
  - on failure: one Slack message, then raise, so the invocation is counted in
    the function's Errors metric
It does not remember the previous run. While the site is down it repeats every
five minutes and it does not announce recovery; AlertManager does both properly.
This is the backstop for when AlertManager's host is what failed.
"""

import json
import logging
import os
import time
import urllib.error
import urllib.request

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

BASE_URL = os.environ.get("PUBLIC_BASE_URL", "").rstrip("/")
SLACK_WEBHOOK_PARAM = os.environ.get("SLACK_WEBHOOK_PARAM", "")
TIMEOUT_SECONDS = float(os.environ.get("PROBE_TIMEOUT_SECONDS", "5"))
RETRY_AFTER_SECONDS = float(os.environ.get("PROBE_RETRY_AFTER_SECONDS", "20"))

# (path, what a 200 on it proves). Ordered from the outside in, so the first
# failure in the list tells you how far a request gets.
CHECKS = [
    ("/nginx-health", "load balancer and nginx"),
    ("/health", "SecureShip, through nginx"),
    ("/ai/health", "RAGService, through nginx"),
]


def check(path):
    """GET one path. Returns a dict that is safe to log and to show in Slack."""
    started = time.monotonic()
    try:
        with urllib.request.urlopen(BASE_URL + path, timeout=TIMEOUT_SECONDS) as resp:
            status, error = resp.status, None
    except urllib.error.HTTPError as exc:      # the server answered, with a 4xx/5xx
        status, error = exc.code, "HTTP %s" % exc.code
    except Exception as exc:                   # no answer: DNS, refused, timeout
        status, error = None, "%s: %s" % (type(exc).__name__, exc)
    return {
        "path": path,
        "ok": status == 200,
        "status": status,
        "error": error,
        "ms": round((time.monotonic() - started) * 1000),
    }


def run_checks(paths):
    return [check(path) for path in paths]


def notify_slack(failed):
    if not SLACK_WEBHOOK_PARAM:
        logger.warning("SLACK_WEBHOOK_PARAM not set; nothing to notify")
        return
    proves = dict(CHECKS)
    lines = ["`%s` (%s): %s" % (r["path"], proves[r["path"]], r["error"]) for r in failed]
    message = {
        "attachments": [{
            "color": "danger",
            "title": "OUTSIDE-IN PROBE FAILED: %s" % BASE_URL,
            "text": "\n".join(lines),
            "footer": "Checked from outside the VPC, twice, %ds apart. "
                      "If Prometheus shows everything up, the fault is in front of the "
                      "services: load balancer, security group, nginx." % RETRY_AFTER_SECONDS,
        }]
    }
    webhook = boto3.client("ssm").get_parameter(
        Name=SLACK_WEBHOOK_PARAM, WithDecryption=True)["Parameter"]["Value"]
    request = urllib.request.Request(
        webhook, data=json.dumps(message).encode(), headers={"Content-Type": "application/json"})
    urllib.request.urlopen(request, timeout=10)


def lambda_handler(event, context):
    if not BASE_URL:
        raise RuntimeError("PUBLIC_BASE_URL is not set")

    results = run_checks([path for path, _ in CHECKS])
    failed = [r for r in results if not r["ok"]]
    if failed:
        time.sleep(RETRY_AFTER_SECONDS)
        retried = {r["path"]: r for r in run_checks([r["path"] for r in failed])}
        results = [retried.get(r["path"], r) for r in results]
        failed = [r for r in results if not r["ok"]]

    logger.info(json.dumps({"event": "probe", "base_url": BASE_URL, "ok": not failed, "checks": results}))

    if failed:
        try:
            notify_slack(failed)
        except Exception as exc:               # never let a Slack problem hide the real one
            logger.error(json.dumps({"event": "notify_failed", "error": str(exc)}))
        raise RuntimeError("probe failed: " + ", ".join(r["path"] for r in failed))

    return {"ok": True, "checks": results}
