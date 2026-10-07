# Verification report: the stack on real AWS infrastructure

**Date:** 2026-10-07
**Duration:** instances up 01:55 UTC – torn down same day (about 8.5 hours, ≈ $1.30)
**Type:** Planned verification (bring-up, functional checks, chaos, rollback, audit, teardown)
**Status:** Closed. One real defect found and fixed during the run (see "Rollback test, attempt 1").

---

## Why this exists

Every other check in this repository had been run locally. Nothing had been checked against real AWS:
real IAM, real security groups, real DynamoDB, a real load balancer, a real deploy over SSM. This is that
run, with commands and results, so every "verified on AWS" claim in the README and in interview answers
points here.

## What was brought up

`bash scripts/infra-up.sh`: Terraform applied 75 resources (no domain), both servers registered with SSM and
finished their boot scripts, and the CI/CD pipeline built four images and deployed them. The run needed two
fixes before it finished cleanly:

- The AWS CLI (Python, on a Windows console using cp1252) crashed printing a boot log that contained an arrow
  character from a systemd symlink message, after the underlying work had already succeeded. Fixed by setting
  `PYTHONUTF8=1` / `PYTHONIOENCODING=utf-8` for the infra scripts.
- Nothing else needed a second attempt at this stage.

## Live checks through the public address

`http://observeops-alb-110023318.ap-south-1.elb.amazonaws.com/`

| Check | Result |
|---|---|
| `GET /api/v1/ships` with no key | 401 |
| `GET /api/v1/ships` with the right key | 200, body returned |
| `GET /api/v1/ships` with a wrong key | 401 |
| `GET /health`, `/ready`, `/nginx-health`, `/ai/health`, `/grafana/api/health` | 200 |
| `GET /prometheus/-/healthy` | 403 (admin path blocked at nginx, by design) |
| `GET /metrics` | 404 (not public, by design) |

The production DynamoDB table is empty (`"ships":[], "total":0`). The three sample ships used in local
demos exist only in the in-memory fallback; nothing seeds the real table, and nothing was asked to.

## Monitoring, checked on the observability server over SSM

- Prometheus: 13 of 13 scrape targets up; 22 alert rules and 8 recording rules loaded.
- Loki: logs present from all 13 containers across both hosts (`alertmanager`, `alloy`, `grafana`,
  `llm-alert-autopilot`, `loki`, `nginx`, `node-exporter`, `otel-collector`, `prometheus`, `ragservice`,
  `secureship`, `statusservice`, `tempo`). `/ready` returned 503 for roughly the first ten minutes after
  start (the ingester was not ready yet), then 200 for the rest of the run. That matches what the local
  stack does and is not a defect.

## Chaos test: kill SecureShip (`scripts/chaos.sh secureship`)

Run directly on the application server. Result: **PASS**.

| Stage | Time after the kill |
|---|---|
| Scrape recorded the target as failed | +5 s |
| Rule entered the pending state | +14 s |
| Rule fired (`for: 1m` elapsed) | +74 s |
| Visible in AlertManager | +74 s |
| Service restarted and healthy again | +7 s after it was started |
| Functional check (`/api/v1/ships` through nginx) | 200 |

Pending to firing took exactly 60 seconds, the rule's `for:` duration. This is the number to quote:
**a killed service's alert fires about 74 seconds later**, inside the 60–105 second window the rule's
design implies (60 s `for:` + up to one 15 s scrape + up to one 15 s evaluation). The Slack notification
follows AlertManager's 30-second `group_wait`, separately.

## Rollback test, attempt 1: a deliberately broken image — FAILED, and found a real bug

Procedure: retag all four services' latest images as `broken` in ECR (SecureShip's `broken` tag points at
an image that exits immediately on start; the other three point at their normal, working manifests so the
pull succeeds). Deploy with `IMAGE_TAG=broken` and watch for the automatic rollback.

**Result: the rollback did not run.** The script printed `Initiating automatic rollback...` and then stopped.
SecureShip was left on the broken image, answering nothing (`health=000`), until a manual
`bash scripts/deploy.sh --rollback` was run to restore service.

**Root cause:** the rollback called `"$0" --rollback`. Run as `bash scripts/deploy.sh`, `$0` is the relative
path `scripts/deploy.sh`, and the file was stored with mode `644` in git (not executable) for every script
in the repository. The call failed with `Permission denied` (exit 126) under `set -e`, which ended the
script without a further message.

**Fix** (commit `7b203fc`): the script now resolves its own absolute path once (`SELF`, from
`${BASH_SOURCE[0]}`) and calls `bash "$SELF" --rollback`, with an explicit error message if that itself
fails. Every script's mode was changed to `755` in git.

## A second bug, found by the fix

Deploying the fix (commit `483eba8`) triggered a normal CI deploy, which **also failed its smoke tests and
rolled back** — a real, if unintended, second use of the rollback path, and it worked. The specific failure:
the smoke test for the alert autopilot made one request 5 seconds after its container was recreated, while
it was still starting (it has a 15-second start period). Every other health check in the script already
polls; this one did not. **Fixed** (commit `9cc9615`): smoke checks now poll each endpoint for up to 60
seconds before failing.

## Rollback test, attempt 2: same broken image, fixed script — PASS

| Step | Result |
|---|---|
| Image before the test | `secureship:9cc9615` (healthy) |
| Deploy with `IMAGE_TAG=broken` | SecureShip recreated, health check failed for 60 s |
| Automatic rollback | Ran `bash "$SELF" --rollback`, rolled back to `9cc9615` |
| Verification | "Rollback verified — SecureShip is healthy on …:9cc9615" |
| Image after the test | `secureship:9cc9615` |
| `/health` after the test | 200 |

The deploy's own exit code is 1 (a failed deploy correctly reports failure even though the rollback
succeeded); that is by design, not a bug.

## Audit alerter: a security-group change outside Terraform

A temporary security group was created in the project's VPC, given one inbound rule, and deleted — nothing
was left behind.

| Event | CloudTrail → API call | Lambda received | Slack sent |
|---|---|---|---|
| `AuthorizeSecurityGroupIngress` | 02:26:11 UTC | 02:26:13.008 | 02:26:15.775 |
| `DeleteSecurityGroup` | 02:26:12 UTC | 02:26:14.958 | 02:26:17.742 |

About two seconds from the API call to the Lambda receiving it, and two more to the Slack post: roughly
**four to five seconds, API call to Slack message**. Two test messages were posted to `#alerts-critical`,
labelled as what they were. Lambda error count for both invocations: 0.

This also confirms the account baseline (`scripts/bootstrap-aws-account.sh`) did its job: without the
CloudTrail trail it creates, these events never reach EventBridge, and the function is never invoked —
which was the actual state of this project for about five months before 7 October.

## Outside-in probe

Armed after the first successful deploy. Invoked every five minutes for the rest of the run with zero
errors, which means every five-minute snapshot found the public URL answering — including after both
chaos experiments above, each of which caused less than two minutes of partial unavailability.

## What was not run on this pass

- The crash scenario (self-healing, no page) and the OOM loop were verified locally earlier the same day,
  not repeated on AWS, to keep the billable window short after finding and fixing the rollback bug.
- The deadman switch's external leg: no `healthchecks_url` parameter exists, so it was not exercised.

## Teardown

`bash scripts/infra-down.sh --yes`. Expected result: both instances, the NAT gateway, the load balancer,
the VPC, DynamoDB, both Lambdas and the ECR repositories (with the `broken` test tags) all removed; the
script's own check confirms nothing billable remains.

## What this changes elsewhere

- README: the "what runs vs. written" table, the numbers, and the known-limits list reflect this run.
- `Project_Defence.html`, section 5: filled from this file.
- The resume and interview-answer figure for detection time is **74 seconds**, measured, not the retired
  42-second figure from 31 May or the never-measured "90 seconds".
