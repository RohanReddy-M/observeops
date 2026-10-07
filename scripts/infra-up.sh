#!/usr/bin/env bash
# Bring ObserveOps up on AWS, deploy to it, and confirm it works.
# One command, about 25 minutes, and it ends with a verdict: up and verified, or
# not, and why.
#
#   bash scripts/infra-up.sh              # production
#   ENV=staging bash scripts/infra-up.sh
#
# What it does, in order:
#   0. checks the tools, the AWS account and the secrets it will need
#   1. terraform apply                    (VPC, 2 EC2, ALB, DynamoDB, 2 Lambdas, ECR ...)
#   2. waits for both instances to finish their first-boot script
#   3. tells GitHub Actions where the new instance and registry are
#   4. starts the CI/CD pipeline and waits for it: build 4 images, deploy, smoke tests
#   5. arms the outside-in probe, now that there is something to probe
#
# What gets deployed is the main branch AS IT IS ON GITHUB. The servers clone it
# at boot and CI builds from it. Commits you have not pushed are not part of it.
#
# Cost while it is up: about $0.15 an hour (NAT gateway, load balancer, two
# t3.small, three public IPv4 addresses). Run scripts/infra-down.sh when you are
# done; nothing bills by the hour while it is down.
#
# Requirements: terraform >= 1.11, aws CLI with credentials for the account, gh
# CLI logged in, and scripts/bootstrap-aws-account.sh run once for the account.
set -euo pipefail

ENV="${ENV:-production}"
REPO="${REPO:-RohanReddy-M/observeops}"
REGION="${AWS_REGION:-ap-south-1}"
export AWS_DEFAULT_REGION="$REGION"
export AWS_PAGER=""
# Git Bash on Windows rewrites arguments that start with "/" into Windows paths
# before they reach a native exe, which mangles SSM parameter names.
export MSYS_NO_PATHCONV=1
# The AWS CLI is Python. On a Windows console its output encoding is cp1252, and
# the server's logs contain arrows (symlink lines). Without this the CLI crashes
# printing a boot log, mid-run, after the work has succeeded.
export PYTHONUTF8=1 PYTHONIOENCODING=utf-8

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
say()  { echo ""; echo "==> $*"; }
fail() { echo ""; echo "!! $*" >&2; exit 1; }

# ── 0. Preflight: fail in the first ten seconds, not after ten minutes ────────
say "Preflight"
for tool in terraform aws gh git; do
    command -v "$tool" >/dev/null 2>&1 || fail "'$tool' is not installed or not on PATH."
done
ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
    || fail "AWS credentials are not working. Try: aws sts get-caller-identity"
gh auth status >/dev/null 2>&1 || fail "gh is not logged in. Run: gh auth login"
echo "    account ${ACCOUNT}, region ${REGION}, repo ${REPO}"

MISSING=""
for name in groq_api_key slack_webhook_critical slack_webhook_warnings; do
    aws ssm get-parameter --name "/observeops/production/${name}" >/dev/null 2>&1 || MISSING="${MISSING} ${name}"
done
if [ -n "$MISSING" ]; then
    echo "    !! missing in SSM Parameter Store:${MISSING}"
    echo "       The stack will come up, but the LLM diagnosis and/or Slack alerts will not work."
    echo "       Create each with:  aws ssm put-parameter --type SecureString --name /observeops/production/<name> --value '<value>'"
    read -r -p "    Continue anyway? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || exit 1
fi
if ! aws ssm get-parameter --name "/observeops/production/healthchecks_url" >/dev/null 2>&1; then
    echo "    note: no healthchecks_url in SSM, so the deadman switch has nowhere to ping (see the README)."
fi

git -C "$ROOT" fetch --quiet origin main || true
LOCAL=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)
REMOTE=$(git -C "$ROOT" rev-parse origin/main 2>/dev/null || echo unknown)
echo "    deploying origin/main at $(git -C "$ROOT" rev-parse --short origin/main 2>/dev/null || echo '?')"
if [ "$LOCAL" != "$REMOTE" ] || [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; then
    echo "    note: your working copy differs from origin/main. Local commits and uncommitted"
    echo "          changes are NOT deployed. Push first if you want them in."
fi

cd "$ROOT/terraform"

say "Initialising Terraform (env: ${ENV})"
terraform init -input=false -reconfigure -backend-config="key=${ENV}/terraform.tfstate" > /dev/null

DOMAIN=$(grep -E '^[[:space:]]*domain_name[[:space:]]*=' "environments/${ENV}.tfvars" 2>/dev/null \
         | tail -1 | sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/' || true)

if [ -n "${DOMAIN:-}" ]; then
    # With a domain, the certificate can only validate once the registrar delegates
    # to the hosted zone Terraform creates. So: create the zone alone, point the
    # registrar at it, and only then apply the rest (which waits on validation).
    say "Domain mode (${DOMAIN}): creating the hosted zone first"
    terraform apply -auto-approve -input=false -var-file="environments/${ENV}.tfvars" \
        -target='module.alb.aws_route53_zone.main'
    NS=$(terraform output -json route53_name_servers | tr -d '[]" \n' | tr ',' '\n' | sed 's/^/Name=/' | tr '\n' ' ')
    echo "    pointing the registrar at the new zone's name servers"
    # shellcheck disable=SC2086
    aws route53domains update-domain-nameservers --region us-east-1 \
        --domain-name "$DOMAIN" --nameservers $NS > /dev/null \
        || echo "    !! Could not update name servers automatically. Set them by hand at the registrar: $NS"
else
    echo "    no domain configured: the load balancer will serve HTTP on its own AWS DNS name"
fi

say "Creating infrastructure (about 5 minutes; the NAT gateway and load balancer are the slow parts)"
terraform apply -auto-approve -input=false -var-file="environments/${ENV}.tfvars"

APP_ID=$(terraform output -raw app_instance_id)
OBS_ID=$(terraform output -raw obs_instance_id)
PUBLIC_URL=$(terraform output -raw live_url)
PROBE_RULE=$(terraform output -raw external_probe_rule_name)
ECR_URL="$(terraform output -raw ecr_secureship_url | cut -d'/' -f1)/observeops"

# ── 2. Wait for first boot to finish ─────────────────────────────────────────
# CI deploys by sending an SSM command to the app server. If that arrives while
# the boot script is still installing Docker, the deploy fails for a reason that
# has nothing to do with the code. So wait until each instance is registered with
# SSM and its boot script has printed its last line, and only then start CI.
wait_for_boot() {   # wait_for_boot <instance-id> <label>
    local id="$1" label="$2" cmd status out
    echo "    ${label} (${id}): waiting to register with SSM"
    for _ in $(seq 1 60); do
        if [ "$(aws ssm describe-instance-information \
                --filters "Key=InstanceIds,Values=${id}" \
                --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null)" = "Online" ]; then
            break
        fi
        sleep 10
    done
    echo "    ${label}: waiting for the boot script (cloud-init) to finish"
    cmd=$(aws ssm send-command --instance-ids "$id" --document-name AWS-RunShellScript \
            --parameters 'commands=["cloud-init status --wait > /dev/null 2>&1; cloud-init status; tail -n 4 /var/log/user-data.log"]' \
            --query 'Command.CommandId' --output text)
    for _ in $(seq 1 90); do
        status=$(aws ssm get-command-invocation --command-id "$cmd" --instance-id "$id" \
                   --query 'Status' --output text 2>/dev/null || echo Pending)
        case "$status" in
            Success)
                out=$(aws ssm get-command-invocation --command-id "$cmd" --instance-id "$id" \
                        --query 'StandardOutputContent' --output text)
                echo "$out" | sed 's/^/        /'
                # "Success" only means the command ran. The boot script prints this
                # line as its last act; if it is missing, the script died part way.
                if echo "$out" | grep -q "Bootstrap complete"; then return 0; fi
                echo "    !! ${label}: the boot script did not reach its end. Read it with:"
                echo "       aws ssm start-session --target ${id}   then   sudo tail -50 /var/log/user-data.log"
                return 1 ;;
            Failed|Cancelled|TimedOut)
                echo "    !! ${label}: boot check ended with ${status}"
                return 1 ;;
        esac
        sleep 10
    done
    echo "    !! timed out waiting for ${label}"; return 1
}

say "Waiting for the two servers to finish booting (about 5 minutes)"
wait_for_boot "$APP_ID" "app server"
wait_for_boot "$OBS_ID" "observability server"

say "Pointing GitHub Actions at the new infrastructure"
gh secret set EC2_INSTANCE_ID --repo "$REPO" --body "$APP_ID"
gh secret set ECR_REGISTRY    --repo "$REPO" --body "$ECR_URL"

# ── 4. Deploy ────────────────────────────────────────────────────────────────
# A manual run of the pipeline on main. This used to push an empty commit to
# trigger it, which put a "trigger deploy" commit in the history for every
# bring-up and pushed whatever else happened to be committed locally.
say "Starting the CI/CD pipeline and waiting for it (build, deploy, smoke tests: about 12 minutes)"
# A little in the past, so a laptop clock that runs slightly ahead of GitHub's
# does not make the new run look older than the moment we asked for it.
STARTED=$(date -u -d '90 seconds ago' +%Y-%m-%dT%H:%M:%SZ)
gh workflow run deploy.yml --repo "$REPO" --ref main
RUN_ID=""
for _ in $(seq 1 30); do
    sleep 4
    RUN_ID=$(gh run list --repo "$REPO" --workflow deploy.yml --event workflow_dispatch --limit 1 \
               --json databaseId,createdAt --jq ".[] | select(.createdAt >= \"${STARTED}\") | .databaseId" 2>/dev/null || true)
    [ -n "$RUN_ID" ] && break
done
[ -n "$RUN_ID" ] || fail "Could not find the pipeline run. Look at: gh run list --repo ${REPO}"
echo "    run ${RUN_ID}: https://github.com/${REPO}/actions/runs/${RUN_ID}"

# Poll and print one line per check, so the wait is not a blank screen.
CONCLUSION=""
for _ in $(seq 1 80); do
    sleep 30
    LINE=$(gh run view "$RUN_ID" --repo "$REPO" --json status,conclusion,jobs \
             --jq '"\(.status)|\(.conclusion // "")|" + ([.jobs[] | select(.status == "in_progress") | .name] | join(", "))' 2>/dev/null || echo "unknown||")
    STATUS="${LINE%%|*}"; REST="${LINE#*|}"; CONCLUSION="${REST%%|*}"; RUNNING="${REST#*|}"
    echo "    $(date +%H:%M:%S)  ${STATUS}${RUNNING:+  running: ${RUNNING}}"
    [ "$STATUS" = "completed" ] && break
done

if [ "$CONCLUSION" != "success" ]; then
    echo ""
    echo "!! The pipeline did not succeed (result: ${CONCLUSION:-still running after 40 minutes})."
    echo "   The infrastructure is UP and billing."
    echo "   See why:      gh run view ${RUN_ID} --repo ${REPO} --log-failed | tail -60"
    echo "   Try again:    gh workflow run deploy.yml --repo ${REPO} --ref main"
    echo "   Or tear down: bash scripts/infra-down.sh"
    exit 1
fi

# ── 5. Arm the outside-in probe ──────────────────────────────────────────────
aws events enable-rule --name "$PROBE_RULE"

echo ""
echo "==> UP and verified: the deploy passed its smoke tests."
echo ""
echo "    Site:        ${PUBLIC_URL}/"
echo "    Grafana:     ${PUBLIC_URL}/grafana/      user admin, password:"
echo "                 aws ssm get-parameter --with-decryption --name /observeops/production/grafana_admin_password --query Parameter.Value --output text"
echo "    Prometheus:  ${PUBLIC_URL}/prometheus/"
echo "    API key:     aws ssm get-parameter --with-decryption --name /observeops/production/secureship_api_key --query Parameter.Value --output text"
echo "    Shell:       aws ssm start-session --target ${APP_ID}     (app)   |   --target ${OBS_ID}   (observability)"
echo ""
echo "    The outside-in probe is armed: every 5 minutes it requests the site from"
echo "    outside the VPC and posts to Slack if it cannot."
echo ""
echo "    This costs about \$0.15 an hour. When you are done:  bash scripts/infra-down.sh"
