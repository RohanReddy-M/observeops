# ObserveOps

An operations platform I built to learn how a production system fails and how it gets watched.
Four small services sit behind nginx. A monitoring stack runs on a second server. Alerts reach Slack
with a first diagnosis written from the service's own logs. Deploys use short-lived AWS credentials,
check each service's health, and roll back by themselves when a check fails.

**Status, 7 October 2026.** It runs locally with Docker Compose. It was deployed to AWS on 7 October 2026,
tested there, and torn down. Nothing is running publicly now. The results are in
[docs/postmortems/2026-10-07-aws-verification.md](docs/postmortems/2026-10-07-aws-verification.md).
The domain the project used, secureship.click, expired on 1 October 2026. The stack does not need a domain.

---

## What runs, and what is only written

Every row says where its evidence is. "Verified on AWS" means it was exercised on the real stack on 7 October 2026.

| Part | State | Evidence |
|---|---|---|
| SecureShip API (FastAPI, DynamoDB) | Runs locally and on AWS | 38 tests. On AWS: no key → 401, right key → 200 |
| StatusService (Flask) | Runs locally and on AWS | 7 tests. Used as the failure injector for chaos tests |
| RAGService (LangGraph, FAISS, Groq) | Runs locally and on AWS | 42 tests, including retrieval against the real embedding model. Answers come from the runbooks, or the service says it has no context |
| LLM alert autopilot | Runs locally and on AWS | 12 tests. Reads the service's logs from Loki, asks a model, posts to Slack. Its output is a hypothesis, not a verified diagnosis |
| nginx front door | Runs locally and on AWS | Routes, rate limits, and the internal-only ingest route checked by hand |
| Prometheus, AlertManager, Grafana (5 dashboards), Loki, Tempo, Grafana Alloy, OpenTelemetry Collector | Runs locally and on AWS | 13 of 13 scrape targets up, on both hosts |
| 22 alert rules and 8 recording rules | Run | Unit tests with `promtool` in CI, including a case that must not fire |
| Alert routing | Runs | Routing decisions tested with `amtool` in CI |
| Chaos test: kill a service | Verified on AWS | Alert firing 74 s after the kill. Stages are measured, not estimated |
| Game days (10 scenarios) | Run locally | Each scenario injects its fault and restores the stack (run 7 Oct 2026) |
| Automatic rollback | Verified on AWS | A broken release is detected by its health check and rolled back to the last healthy image |
| Audit alerter (Lambda) | Verified on AWS | A security-group change reached Slack about four seconds after the API call |
| Outside-in probe (Lambda) | Deployed on AWS, armed after the first deploy | Requests the public URL every five minutes from outside the VPC |
| Deadman switch (`Watchdog`) | Routing is in place and tested. **The external heartbeat is not configured**, so the ping goes nowhere until its URL is stored in SSM | `monitoring/alertmanager/alertmanager.yml` |
| Terraform (75 resources) | Plan and apply ran on AWS | `terraform/`. State in S3 with a lock file |
| CI/CD (GitHub Actions, OIDC) | Ran on AWS: build, deploy, smoke tests | `.github/workflows/deploy.yml` |
| Kubernetes manifests | Written. Not applied to any cluster | `kubernetes/` |
| EKS cluster definition | Written. Never created | `kubernetes/eks/cluster.yaml` |

---

## Architecture

```
                      internet
                          |
              Application Load Balancer (HTTP, two public subnets)
                          |
  ======== application server (private subnet 10.0.3.0/24) ========
  |  nginx :80 ---- /api/, /health ---> SecureShip :8001 --> DynamoDB |
  |            ---- /status/, /fail ---> StatusService :8002          |
  |            ---- /ai/ -------------> RAGService :8003 (FAISS, Groq)  |
  |  alert autopilot :8080  <- AlertManager webhook; reads Loki; asks Groq; posts to Slack
  |  OpenTelemetry Collector -> traces;  Grafana Alloy -> logs;  node-exporter
  ==================================================================
                          ^ scrapes, alerts, logs, traces
  ======== observability server (private subnet 10.0.4.0/24) ======
  |  Prometheus :9090 (35 days) · AlertManager :9093 · Grafana :3000 |
  |  Loki :3100 · Tempo :3200 · node-exporter                         |
  ==================================================================

  Outside the VPC:  Lambda outside-in probe (every five minutes)
                    Lambda audit alerter (CloudTrail events Terraform did not cause -> Slack)
  AWS services:     ECR (four images) · SSM Parameter Store (secrets) · S3 (state) · CloudTrail
```

The reasoning for each part is in [docs/adr/](docs/adr/). Start with
[ADR-001](docs/adr/001-two-server-architecture.md) (why two servers) and
[ADR-013](docs/adr/013-access-is-scoped-to-roles.md) (access and what is still open).

---

## Run it locally

You need Docker Desktop and Git Bash (on Windows) or a Unix shell. Python 3.11 is needed only for the tests.

```bash
cp .env.example .env              # put your Groq key in GROQ_API_KEY (free at console.groq.com)
docker compose up -d --wait       # about two minutes the first time: images are built
```

| Where | URL | Login |
|---|---|---|
| nginx, the front door | http://localhost/ | none |
| SecureShip API | http://localhost:8001/api/v1/ships | none locally (no key configured) |
| RAG service | http://localhost:8003/health | none |
| Prometheus | http://localhost:9090/prometheus/ | none |
| AlertManager | http://localhost:9093 | none |
| Grafana | http://localhost:3000/grafana/ | `admin` / `observeops123` (local default only) |
| Grafana Alloy (log shipper) | http://localhost:9080/graph | none |

Stop it with `docker compose down`. The local stack uses a few gigabytes of memory.

There is no required `make` step on Windows: every Makefile target is a plain command you can copy.

---

## Tests and checks

| What | Command |
|---|---|
| SecureShip | `pytest apps/secureship/tests -q` |
| StatusService | `pytest apps/statusservice/tests -q` |
| RAG service (downloads an 80 MB model the first time) | `pytest apps/ragservice/tests -q` |
| Alert autopilot | `pytest apps/llm-alert-autopilot/tests -q` |
| Lambda handlers | `pytest apps/lambda/tests -q` |
| Alert rules, as CI runs them | `docker run --rm -v "$PWD/monitoring/prometheus:/rules" --entrypoint promtool prom/prometheus:v3.15.0 test rules /rules/tests/alerts_test.yml` |
| Compose file | `docker compose config --quiet` |
| Kill a service and time the alert | `bash scripts/chaos.sh secureship` (with the stack running) |
| Crash a service and check it heals | `bash scripts/chaos.sh secureship --scenario=crash` |
| Diagnose a failure you were not told about | `python scripts/gameday.py start`, then `hint`, `reveal` or `abort` |

The alert-timing script, [scripts/alert_timeline.py](scripts/alert_timeline.py), reports each stage of an
alert against Prometheus's own record. The chaos script writes a postmortem template with the measured timeline.

---

## Deploy to AWS

This costs about **$0.15 an hour** while it is up. Nothing bills while it is down.

1. **Once per account:** `bash scripts/bootstrap-aws-account.sh`. It creates the state bucket, the GitHub identity
   provider, the CI role (which only `main` and the `production` environment may assume), a CloudTrail trail,
   and the GitHub environment rule.
2. **Secrets in Parameter Store** (you create these; the script lists what is missing):
   `groq_api_key`, `slack_webhook_critical`, `slack_webhook_warnings`. Everything else is generated by Terraform.
3. **Bring it up:** `bash scripts/infra-up.sh`. It applies Terraform, waits for both servers to finish booting,
   runs the pipeline, and arms the outside-in probe. About 25 minutes.
4. **Take it down:** `bash scripts/infra-down.sh --yes`. About six minutes. It ends by checking that nothing that
   bills by the hour is left.

A domain is optional. Set `domain_name` in `terraform/environments/production.tfvars` and see
[ADR-011](docs/adr/011-one-configuration-everywhere.md). Without one the site is served over HTTP on the load
balancer's own address.

---

## Numbers

| | |
|---|---|
| Alert rules | 22 in 8 groups, plus 8 recording rules |
| Grafana dashboards | 5 |
| Automated tests | 109 (SecureShip 38, RAG 42, autopilot 12, Lambda 10, StatusService 7), plus alert-rule and routing tests in CI |
| Terraform resources | 75 (no-domain mode) |
| Architecture decision records | 13 |
| Runbooks | 9. The RAG service answers questions from these same files |
| SLO | SecureShip availability 99.5% over 30 days (error budget 216 minutes); RAG success 95% |
| Measured detection | A killed service's alert is firing 74 s later (scrape failed +5 s, pending +14 s, firing +74 s) |

---

## Security, in short

Access is granted per role, to named ports or resources. There is no SSH anywhere: administration uses Session
Manager, which opens no inbound port. Secrets are generated or stored in Parameter Store and read at start-up.
The CI role uses OIDC, so no AWS keys are stored in GitHub. [ADR-013](docs/adr/013-access-is-scoped-to-roles.md)
lists what is still wide, and that list is the honest part.

---

## Known limits

- One instance per role, and one NAT gateway in one zone. If the NAT gateway fails, both servers lose outbound access.
- Outbound traffic from both servers is not restricted.
- Prometheus is readable from the internet at `/prometheus/`. Its admin endpoints are blocked.
- StatusService's `/fail` and `/load` are public. They exist to cause errors and load.
- One API key is shared by all clients, with no rotation procedure.
- The log shipper mounts the Docker socket, which is root on that host.
- IAM events are not reported: IAM is a global service, and its events reach EventBridge only in us-east-1.
- The deadman switch needs its external URL before it does anything.
- Nothing alerts when log ingestion stops. The shipper's own counters show it, but no rule watches them yet.
- The RAG index is in memory and rebuilt from the runbooks at start-up. The grounding threshold was set by hand,
  and answer quality is not measured against a labelled set.
- The DynamoDB list endpoint reads the whole table. Fine for a small table; the fix is an index and a query.
- The AWS table is empty. The sample ships exist only in local mode.
- The autopilot's diagnosis is a model's hypothesis. It has been seen to name a harmless message as the cause.

---

## Decisions

| # | Decision |
|---|---|
| [001](docs/adr/001-two-server-architecture.md) | Monitoring on a separate server from what it monitors |
| [002](docs/adr/002-ssm-over-ssh.md) | Session Manager instead of SSH |
| [003](docs/adr/003-dynamodb-over-rds.md) | DynamoDB for a key-value registry |
| [004](docs/adr/004-oidc-over-iam-keys.md) | OIDC for CI, no stored AWS keys |
| [005](docs/adr/005-rag-with-grounding-check.md) | RAG with a grounding check that refuses to answer |
| [006](docs/adr/006-prometheus-over-managed-monitoring.md) | Self-hosted Prometheus, Grafana, Loki |
| [007](docs/adr/007-deadman-switch.md) | A deadman switch for the alerting pipeline |
| [008](docs/adr/008-image-digest-pinning.md) | Version tags for images, and why not digests |
| [009](docs/adr/009-llm-provider-groq.md) | A hosted model provider (the model it named has since been retired) |
| [010](docs/adr/010-llm-model-is-configuration.md) | The model name is configuration |
| [011](docs/adr/011-one-configuration-everywhere.md) | One configuration for laptop and AWS; no domain required |
| [012](docs/adr/012-test-the-monitoring.md) | The monitoring is code, so it is tested and measured |
| [013](docs/adr/013-access-is-scoped-to-roles.md) | Access is scoped to roles, named ports and resources |

---

## Repository layout

```
apps/            the four services and the Lambda functions, each with its own tests
monitoring/      Prometheus rules and tests, AlertManager, Alloy, Grafana, Loki, Tempo, OpenTelemetry
terraform/       the AWS stack: network, security groups, compute, load balancer, DynamoDB, Lambda, ECR
kubernetes/      manifests, an EKS cluster definition and an Argo CD layout: written, not applied
scripts/         deploy, bring-up and teardown, account baseline, chaos, game days, timing
docs/adr/        thirteen decision records
docs/runbooks/   nine runbooks, which the RAG service answers from
docs/postmortems/ measured experiments and what they showed
analytics/       a small PySpark batch and streaming example, run locally
```

---

## A note on honesty

Everything marked "verified on AWS" was run on the stack on 7 October 2026, and its output is in the
postmortem. Everything marked "written" has never run in the way its file describes. Where a number here
came from a measurement, the measurement is named. Where it came from a design, it is called a design.
