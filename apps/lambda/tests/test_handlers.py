"""
Tests for the two Lambda handlers.
Run: pytest apps/lambda/tests/ -v

Nothing here touches AWS. The probe is pointed at a tiny HTTP server started in
this process, and the Slack call is replaced with a recorder, so the tests check
the handlers' decisions (what counts as a failure, when to notify, what the
message says) rather than the network.
"""
import importlib.util
import json
import os
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest

HERE = os.path.dirname(__file__)


def load(name):
    """Both handlers are called handler.py, so load each under its own module name."""
    path = os.path.join(HERE, "..", name, "handler.py")
    spec = importlib.util.spec_from_file_location(name + "_handler", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# ─── A stand-in for the public site ───────────────────────────────────────────
class FakeSite:
    """Serves the three probed paths. `plan` maps a path to the status codes it
    returns on successive requests; the last one repeats."""

    def __init__(self):
        self.plan = {}
        self.hits = []
        site = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                site.hits.append(self.path)
                codes = site.plan.get(self.path, [200])
                code = codes.pop(0) if len(codes) > 1 else codes[0]
                self.send_response(code)
                self.end_headers()
                self.wfile.write(b"ok")

            def log_message(self, *args):       # keep test output quiet
                pass

        self.server = HTTPServer(("127.0.0.1", 0), Handler)
        self.url = "http://127.0.0.1:%d" % self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


@pytest.fixture
def site():
    fake = FakeSite()
    yield fake
    fake.close()


@pytest.fixture
def probe(site, monkeypatch):
    module = load("external_probe")
    monkeypatch.setattr(module, "BASE_URL", site.url)
    monkeypatch.setattr(module, "RETRY_AFTER_SECONDS", 0)
    monkeypatch.setattr(module, "TIMEOUT_SECONDS", 2)
    module.notified = []
    monkeypatch.setattr(module, "notify_slack", lambda failed: module.notified.append(failed))
    return module


# ─── Outside-in probe ─────────────────────────────────────────────────────────
def test_probe_passes_when_every_path_answers_200(probe, site):
    result = probe.lambda_handler({}, None)
    assert result["ok"] is True
    assert [c["path"] for c in result["checks"]] == ["/nginx-health", "/health", "/ai/health"]
    assert probe.notified == []


def test_probe_fails_loudly_when_a_path_stays_down(probe, site):
    site.plan["/ai/health"] = [502]
    with pytest.raises(RuntimeError, match="/ai/health"):      # raising is what counts it as an Error
        probe.lambda_handler({}, None)
    assert len(probe.notified) == 1
    assert [f["path"] for f in probe.notified[0]] == ["/ai/health"]
    assert probe.notified[0][0]["status"] == 502


def test_probe_does_not_page_for_a_blip_that_clears_on_the_retry(probe, site):
    """nginx is recreated for a few seconds during every deploy."""
    site.plan["/health"] = [503, 200]
    result = probe.lambda_handler({}, None)
    assert result["ok"] is True
    assert probe.notified == []
    assert site.hits.count("/health") == 2                     # it really did ask twice
    assert site.hits.count("/nginx-health") == 1               # and only re-asked what failed


def test_probe_reports_no_answer_differently_from_a_bad_answer(probe, site, monkeypatch):
    """A refused connection has no status code; the error must say what happened."""
    monkeypatch.setattr(probe, "BASE_URL", "http://127.0.0.1:9")   # nothing listens there
    with pytest.raises(RuntimeError):
        probe.lambda_handler({}, None)
    failure = probe.notified[0][0]
    assert failure["status"] is None
    assert failure["error"]                                    # e.g. "URLError: ... refused"


def test_probe_still_fails_when_slack_itself_is_broken(probe, site, monkeypatch):
    """A notification problem must not hide the outage it was reporting."""
    site.plan["/health"] = [500]

    def broken(_failed):
        raise OSError("slack unreachable")
    monkeypatch.setattr(probe, "notify_slack", broken)
    with pytest.raises(RuntimeError, match="probe failed"):
        probe.lambda_handler({}, None)


def test_probe_refuses_to_run_without_a_url(probe, monkeypatch):
    monkeypatch.setattr(probe, "BASE_URL", "")
    with pytest.raises(RuntimeError, match="PUBLIC_BASE_URL"):
        probe.lambda_handler({}, None)


# ─── Audit alerter ────────────────────────────────────────────────────────────
def cloudtrail_event(name, params, user_agent="aws-cli/2.36.48"):
    """The shape EventBridge delivers for 'AWS API Call via CloudTrail'."""
    return {
        "source": "aws.ec2",
        "detail-type": "AWS API Call via CloudTrail",
        "detail": {
            "eventName": name,
            "eventTime": "2026-10-07T04:12:09Z",
            "awsRegion": "ap-south-1",
            "sourceIPAddress": "203.0.113.50",
            "userAgent": user_agent,
            "userIdentity": {"type": "IAMUser", "arn": "arn:aws:iam::123456789012:user/someone"},
            "requestParameters": params,
        },
    }


@pytest.fixture
def audit(monkeypatch):
    module = load("audit_alerter")
    module.sent = []

    class _Response:
        status = 200

    def fake_urlopen(request, timeout=None):
        module.sent.append(json.loads(request.data.decode()))
        return _Response()

    monkeypatch.setattr(module, "get_slack_webhook", lambda: "https://hooks.example.invalid/x")
    monkeypatch.setattr(module.urllib.request, "urlopen", fake_urlopen)
    return module


def test_audit_message_says_who_did_what_from_where(audit):
    event = cloudtrail_event("AuthorizeSecurityGroupIngress", {"groupId": "sg-0abc123"})
    audit.lambda_handler(event, None)

    assert len(audit.sent) == 1
    attachment = audit.sent[0]["attachments"][0]
    fields = {f["title"]: f["value"] for f in attachment["fields"]}
    assert "AuthorizeSecurityGroupIngress" in attachment["title"]
    assert fields["Who"] == "arn:aws:iam::123456789012:user/someone"
    assert fields["Source IP"] == "203.0.113.50"
    assert fields["Resource"] == "Security Group: `sg-0abc123`"
    assert attachment["color"] == "warning"


def test_audit_names_the_instances_that_were_terminated(audit):
    params = {"instancesSet": {"items": [{"instanceId": "i-0aaa"}, {"instanceId": "i-0bbb"}]}}
    audit.lambda_handler(cloudtrail_event("TerminateInstances", params), None)
    attachment = audit.sent[0]["attachments"][0]
    fields = {f["title"]: f["value"] for f in attachment["fields"]}
    assert fields["Resource"] == "Instances: `i-0aaa, i-0bbb`"
    assert attachment["color"] == "danger"


def test_audit_ignores_an_event_it_does_not_watch(audit):
    result = audit.lambda_handler(cloudtrail_event("DescribeInstances", {}), None)
    assert result["body"] == "ignored"
    assert audit.sent == []


def test_audit_raises_when_slack_fails_so_the_event_reaches_the_dead_letter_queue(audit, monkeypatch):
    def boom(request, timeout=None):
        raise OSError("slack unreachable")
    monkeypatch.setattr(audit.urllib.request, "urlopen", boom)
    with pytest.raises(OSError):
        audit.lambda_handler(cloudtrail_event("DeleteTable", {"tableName": "observeops-ships"}), None)
