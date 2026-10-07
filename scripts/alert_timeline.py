#!/usr/bin/env python3
"""Measure how long the alerting pipeline takes, stage by stage.

Used by scripts/chaos.sh, and usable on its own:

    python scripts/alert_timeline.py --job ragservice --preflight
    python scripts/alert_timeline.py --job ragservice --t0 "$(date +%s)"

After a failure is injected at time t0 it polls Prometheus and AlertManager once
a second and records when each stage is first observed:

    scrape_failed   Prometheus's own `up` series for the job reads 0
    pending         the alert rule is true but still inside its `for:` window
    firing          `for:` has elapsed; Prometheus has started sending the alert
    alertmanager    the alert is active in AlertManager's API

Why measure the stages separately. "The alert fired in N seconds" hides which
part of the pipeline the time went to, and makes an impossible number look
plausible. With a 15s scrape interval, a 15s evaluation interval and `for: 1m`,
an alert CANNOT be firing sooner than 60s after the first evaluation that saw
the failure, so 60-90s after the failure itself.

It can be later. What this tool reports is when each stage becomes OBSERVABLE
through the API, which is what an operator or AlertManager actually experiences.
Prometheus's own bookkeeping (`activeAt`) can read earlier: on a host where the
rule evaluator's query timestamp trails the wall clock by an interval (seen on
Docker Desktop, where it lagged by one full 15s interval), the alert is created
one evaluation late with a backdated activeAt, and fires one evaluation late
too. So expect 60-90s on a well-behaved host and up to about 105s on one like
that; `curl <prometheus>/api/v1/rules` shows activeAt next to lastEvaluation if
you want to see the gap for yourself. A recorded figure of 42s for
this rule was what prompted writing this tool: it could not have been a
measurement of this pipeline, and the old method (a 5-second poll of one
endpoint, timed from after the kill, with no check that an alert was not already
active) had no way to show why.

AlertManager's group_wait is NOT included in any of these stages. It delays the
notification that AlertManager sends onward (Slack, the webhook); the alert is
already visible in AlertManager's API the moment Prometheus delivers it.

Standard library only, so it runs anywhere Python 3 does.
"""
import argparse
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


def get_json(url, timeout=3.0):
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def prom_up(prom, job):
    """Latest value of up{job=...}, or None if there is no such series (yet)."""
    q = urllib.parse.urlencode({"query": 'up{job="%s"}' % job})
    try:
        data = get_json("%s/api/v1/query?%s" % (prom, q))
    except (urllib.error.URLError, OSError, ValueError):
        return None
    result = data.get("data", {}).get("result", [])
    if not result:
        return None
    # A job can have several targets; the job is "down" for our purposes when any is.
    return min(float(r["value"][1]) for r in result)


def prom_alert_state(prom, alert, job):
    """'pending', 'firing' or None for the given alert and job."""
    try:
        data = get_json("%s/api/v1/alerts" % prom)
    except (urllib.error.URLError, OSError, ValueError):
        return None
    best = None
    for a in data.get("data", {}).get("alerts", []):
        labels = a.get("labels", {})
        if labels.get("alertname") == alert and labels.get("job") == job:
            if a.get("state") == "firing":
                return "firing"
            if a.get("state") == "pending":
                best = "pending"
    return best


def am_active(am, alert, job):
    """True when the alert is active in AlertManager."""
    try:
        data = get_json("%s/api/v2/alerts?active=true&silenced=false&inhibited=false" % am)
    except (urllib.error.URLError, OSError, ValueError):
        return False
    for a in data:
        labels = a.get("labels", {})
        if (labels.get("alertname") == alert and labels.get("job") == job
                and a.get("status", {}).get("state") == "active"):
            return True
    return False


def preflight(args):
    """A measurement is only meaningful from a clean baseline."""
    problems = []
    up = prom_up(args.prom, args.job)
    if up is None:
        problems.append("Prometheus has no up{job=\"%s\"} series (is it running, is the job scraped?)" % args.job)
    elif up != 1:
        problems.append("up{job=\"%s\"} is %s, not 1: the target is already down" % (args.job, up))
    state = prom_alert_state(args.prom, args.alert, args.job)
    if state:
        problems.append("%s is already %s in Prometheus for job %s" % (args.alert, state, args.job))
    if am_active(args.am, args.alert, args.job):
        problems.append("%s is already active in AlertManager for job %s "
                        "(a previous run has not resolved yet; wait a few minutes)" % (args.alert, args.job))
    if problems:
        print("PREFLIGHT FAILED: not a clean baseline, so any timing would be meaningless:")
        for p in problems:
            print("  - " + p)
        return 1
    print("PREFLIGHT OK: %s is up and %s is neither pending nor firing" % (args.job, args.alert))
    return 0


def measure(args):
    t0 = args.t0 if args.t0 else time.time()
    seen = {}            # stage -> seconds after t0
    order = ["scrape_failed", "pending", "firing", "alertmanager"]
    deadline = t0 + args.timeout
    last_line = ""

    while time.time() < deadline:
        now = time.time() - t0
        if "scrape_failed" not in seen and prom_up(args.prom, args.job) == 0:
            seen["scrape_failed"] = now
        state = prom_alert_state(args.prom, args.alert, args.job)
        if state in ("pending", "firing") and "pending" not in seen:
            seen["pending"] = now
        if state == "firing" and "firing" not in seen:
            seen["firing"] = now
        if "alertmanager" not in seen and am_active(args.am, args.alert, args.job):
            seen["alertmanager"] = now

        # Print only when a stage is first observed, not once a second.
        stages = "  ".join("%s=%s" % (k, ("%ds" % seen[k]) if k in seen else "-") for k in order)
        if stages != last_line and not args.quiet:
            print("  +%3ds  %s" % (now, stages), flush=True)
            last_line = stages
        if "alertmanager" in seen and "firing" in seen:
            break
        time.sleep(1.0)

    print("")
    print("Alert pipeline timeline for %s / job=%s (seconds after the failure was injected)" % (args.alert, args.job))
    explain = {
        "scrape_failed": "Prometheus's next scrape of the target failed (0 to one scrape interval)",
        "pending":       "a rule evaluation saw it (within one evaluation interval, two if the evaluator trails the clock)",
        "firing":        "the rule's `for:` duration elapsed while it stayed true",
        "alertmanager":  "Prometheus delivered it; AlertManager now shows it active",
    }
    for k in order:
        value = ("%5.0fs" % seen[k]) if k in seen else "  not observed"
        print("  %-14s %s   %s" % (k, value, explain[k]))
    if "pending" in seen and "firing" in seen:
        print("  pending -> firing took %.0fs (the rule's `for:` window)" % (seen["firing"] - seen["pending"]))
    print("  Notifications (Slack, webhooks) follow up to group_wait later; that is not measured here.")

    # Machine-readable line for chaos.sh
    print("TIMELINE " + " ".join(
        "%s=%s" % (k.upper(), int(round(seen[k])) if k in seen else "NONE") for k in order))
    return 0 if "alertmanager" in seen else 3


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--job", required=True, help="Prometheus job label of the target, e.g. ragservice")
    ap.add_argument("--alert", default="ServiceDown")
    ap.add_argument("--prom", default="http://localhost:9090/prometheus",
                    help="Prometheus base URL including its route prefix")
    ap.add_argument("--am", default="http://localhost:9093", help="AlertManager base URL")
    ap.add_argument("--t0", type=float, default=0.0, help="epoch seconds when the failure was injected")
    ap.add_argument("--timeout", type=int, default=180)
    ap.add_argument("--preflight", action="store_true", help="only check for a clean baseline, then exit")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()
    args.prom = args.prom.rstrip("/")
    args.am = args.am.rstrip("/")
    return preflight(args) if args.preflight else measure(args)


if __name__ == "__main__":
    sys.exit(main())
