#!/usr/bin/env bash
# ─── Account baseline for ObserveOps ──────────────────────────────────────────
# The few things that must exist in an AWS account BEFORE `terraform apply` or a
# GitHub Actions deploy can work, and that should outlive the application stack:
#
#   1. Terraform state bucket     observeops-terraform-state-<account-id>
#                                 versioned, encrypted, private. State is locked
#                                 with an S3 lock file (use_lockfile), so there is
#                                 no DynamoDB lock table any more.
#   2. GitHub OIDC provider       lets GitHub Actions prove who it is to AWS
#   3. CI deploy role             observeops-github-actions. Can be assumed only
#                                 from this repository's main branch or its
#                                 `production` environment, and can only push the
#                                 project's images and run the deploy on the
#                                 project's instances.
#   4. CloudTrail trail           observeops-audit, all regions. Without a trail
#                                 EventBridge never sees API calls, and the audit
#                                 alerter Lambda can never fire.
#   5. GitHub environment         `production` may only be deployed from main
#   6. Optional budget            account-guardrail, $5/month, email at 80%
#   7. Optional secret copy       /observeops/production/* from another profile
#   8. Repo                       backend bucket name and registry account id
#
# Why a script and not Terraform: Terraform needs the state bucket to exist
# before it can run, and the role CI uses must not be something CI's own
# `terraform destroy` can delete. This layer is the ground the stack stands on.
# It is cheap (cents a month) and stays up; the stack is torn down between uses.
#
# Every step is idempotent: run it again and it converges to the same result.
#
# Usage (Git Bash, from the repo root, with credentials for the account):
#   bash scripts/bootstrap-aws-account.sh
#   BUDGET_EMAIL=you@example.com bash scripts/bootstrap-aws-account.sh
#   AWS_PROFILE=new COPY_SECRETS_FROM=old bash scripts/bootstrap-aws-account.sh
#   bash scripts/bootstrap-aws-account.sh --yes        # no confirmation prompt
set -euo pipefail
export AWS_PAGER=""
# Git Bash rewrites arguments that start with "/" into Windows paths before they
# reach a native exe, which turns /observeops/production/x into
# C:/Program Files/Git/observeops/... Turn that conversion off for this script.
export MSYS_NO_PATHCONV=1

REGION="${AWS_REGION:-ap-south-1}"
REPO="${REPO:-RohanReddy-M/observeops}"
PROJECT="observeops"
ROLE_NAME="observeops-github-actions"
TRAIL_NAME="observeops-audit"
GH_OIDC_URL="token.actions.githubusercontent.com"
SECRET_NAMES=(
  /observeops/production/groq_api_key
  /observeops/production/slack_webhook_critical
  /observeops/production/slack_webhook_warnings
)

log()  { printf '\033[0;34m[bootstrap]\033[0m %s\n' "$*"; }
ok()   { printf '\033[0;32m[ok]\033[0m %s\n' "$*"; }
skip() { printf '\033[0;33m[skip]\033[0m %s\n' "$*"; }

# AWS CLI on Windows is a native exe: give it a Windows path inside file:// URIs.
file_uri() { if command -v cygpath >/dev/null 2>&1; then echo "file://$(cygpath -m "$1")"; else echo "file://$1"; fi; }
TMP_DIR="$(mktemp -d)"; trap 'rm -rf "$TMP_DIR"' EXIT

# ── 0. Which account? Say it out loud before changing anything ────────────────
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
CALLER="$(aws sts get-caller-identity --query Arn --output text)"
log "Account $ACCOUNT_ID ($CALLER), region $REGION, repo $REPO"
if [[ -n "${COPY_SECRETS_FROM:-}" ]]; then
  SRC_ACCOUNT="$(AWS_PROFILE="$COPY_SECRETS_FROM" aws sts get-caller-identity --query Account --output text)"
  [[ "$SRC_ACCOUNT" != "$ACCOUNT_ID" ]] || { echo "COPY_SECRETS_FROM points at the same account ($ACCOUNT_ID). Nothing to copy."; exit 1; }
fi
if [[ "${1:-}" != "--yes" ]]; then
  read -r -p "Apply the baseline to account $ACCOUNT_ID? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

STATE_BUCKET="observeops-terraform-state-${ACCOUNT_ID}"
TRAIL_BUCKET="observeops-cloudtrail-${ACCOUNT_ID}"

make_private_bucket() {   # make_private_bucket <name>
  if aws s3api head-bucket --bucket "$1" >/dev/null 2>&1; then
    skip "bucket $1 exists"
  else
    aws s3api create-bucket --bucket "$1" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
    ok "created bucket $1"
  fi
  aws s3api put-bucket-encryption --bucket "$1" --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  aws s3api put-public-access-block --bucket "$1" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
}

# ── 1. Terraform state bucket ─────────────────────────────────────────────────
# Versioning is what makes a bad apply recoverable: every state write keeps the
# previous version, so "restore yesterday's state" is an S3 operation.
make_private_bucket "$STATE_BUCKET"
aws s3api put-bucket-versioning --bucket "$STATE_BUCKET" --versioning-configuration Status=Enabled
ok "state bucket: versioned, encrypted, public access blocked"

# ── 2. GitHub OIDC provider ───────────────────────────────────────────────────
PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${GH_OIDC_URL}"
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$PROVIDER_ARN" >/dev/null 2>&1; then
  skip "OIDC provider exists"
else
  aws iam create-open-id-connect-provider --url "https://${GH_OIDC_URL}" \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 1c58a3a8518e8759bf075b76b750d4f2df264fcd >/dev/null
  ok "created GitHub OIDC provider"
fi

# ── 3. CI deploy role ─────────────────────────────────────────────────────────
# WHO may assume it. GitHub signs a token for every job; its `sub` claim says
# where the job runs. Two shapes are accepted and nothing else:
#   repo:<repo>:ref:refs/heads/main        a job on the main branch (image build)
#   repo:<repo>:environment:production     a job that declared that environment (deploy)
# This used to be "repo:<repo>:*": any branch, any pull request from a branch of
# this repository, any workflow file anyone could push.
cat > "$TMP_DIR/trust.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "${PROVIDER_ARN}" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${GH_OIDC_URL}:aud": "sts.amazonaws.com",
        "${GH_OIDC_URL}:sub": [
          "repo:${REPO}:ref:refs/heads/main",
          "repo:${REPO}:environment:production"
        ]
      }
    }
  }]
}
EOF

# WHAT it may do: exactly the calls .github/workflows/deploy.yml makes.
# This used to be the AWS managed policies AmazonSSMFullAccess and
# AmazonEC2ContainerRegistryPowerUser. With the first one CI could read every
# secret in Parameter Store and run commands on any instance in the account.
cat > "$TMP_DIR/push-images.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "RegistryLogin", "Effect": "Allow", "Action": "ecr:GetAuthorizationToken", "Resource": "*" },
    { "Sid": "PushAndPullThisProjectsImages", "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"
      ],
      "Resource": "arn:aws:ecr:${REGION}:${ACCOUNT_ID}:repository/${PROJECT}/*" }
  ]
}
EOF
cat > "$TMP_DIR/deploy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "FindTheAppServer", "Effect": "Allow",
      "Action": ["ec2:DescribeInstances", "ec2:DescribeTags"], "Resource": "*" },
    { "Sid": "ReadTheObsServerAddress", "Effect": "Allow", "Action": "ssm:GetParameter",
      "Resource": "arn:aws:ssm:${REGION}:${ACCOUNT_ID}:parameter/${PROJECT}/production/obs_server_ip" },
    { "Sid": "RunCommandsOnlyOnThisProjectsInstances", "Effect": "Allow", "Action": "ssm:SendCommand",
      "Resource": "arn:aws:ec2:${REGION}:${ACCOUNT_ID}:instance/*",
      "Condition": { "StringEquals": { "ssm:resourceTag/Project": "${PROJECT}" } } },
    { "Sid": "OnlyTheShellScriptDocument", "Effect": "Allow", "Action": "ssm:SendCommand",
      "Resource": "arn:aws:ssm:${REGION}::document/AWS-RunShellScript" },
    { "Sid": "ReadTheResultOfTheCommand", "Effect": "Allow",
      "Action": ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"], "Resource": "*" }
  ]
}
EOF
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "$(file_uri "$TMP_DIR/trust.json")"
  skip "role $ROLE_NAME exists (trust policy set)"
else
  aws iam create-role --role-name "$ROLE_NAME" \
    --description "GitHub Actions deploy role for ${REPO} (OIDC, no static keys)" \
    --assume-role-policy-document "$(file_uri "$TMP_DIR/trust.json")" >/dev/null
  ok "created role $ROLE_NAME"
fi
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name push-project-images \
  --policy-document "$(file_uri "$TMP_DIR/push-images.json")"
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name deploy-via-ssm \
  --policy-document "$(file_uri "$TMP_DIR/deploy.json")"
# Remove what earlier versions of this script attached.
for arn in arn:aws:iam::aws:policy/AmazonSSMFullAccess arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser; do
  aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$arn" 2>/dev/null && ok "detached $(basename "$arn")" || true
done
aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name ec2-describe-readonly 2>/dev/null || true
ROLE_ARN="$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text)"
ok "CI role: main branch and production environment only; push project images, deploy to project instances"

# ── 4. CloudTrail ─────────────────────────────────────────────────────────────
# Every account keeps 90 days of API history for free, but that history is only
# for looking things up. Events are DELIVERED (to S3, and to EventBridge as "AWS
# API Call via CloudTrail") only when a trail exists. The first trail's
# management events cost nothing; the bucket holds a few megabytes.
make_private_bucket "$TRAIL_BUCKET"
TRAIL_ARN="arn:aws:cloudtrail:${REGION}:${ACCOUNT_ID}:trail/${TRAIL_NAME}"
cat > "$TMP_DIR/trail-bucket.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "AWSCloudTrailAclCheck", "Effect": "Allow",
      "Principal": { "Service": "cloudtrail.amazonaws.com" },
      "Action": "s3:GetBucketAcl", "Resource": "arn:aws:s3:::${TRAIL_BUCKET}",
      "Condition": { "StringEquals": { "aws:SourceArn": "${TRAIL_ARN}" } } },
    { "Sid": "AWSCloudTrailWrite", "Effect": "Allow",
      "Principal": { "Service": "cloudtrail.amazonaws.com" },
      "Action": "s3:PutObject", "Resource": "arn:aws:s3:::${TRAIL_BUCKET}/AWSLogs/${ACCOUNT_ID}/*",
      "Condition": { "StringEquals": { "s3:x-amz-acl": "bucket-owner-full-control", "aws:SourceArn": "${TRAIL_ARN}" } } }
  ]
}
EOF
aws s3api put-bucket-policy --bucket "$TRAIL_BUCKET" --policy "$(file_uri "$TMP_DIR/trail-bucket.json")"
aws s3api put-bucket-lifecycle-configuration --bucket "$TRAIL_BUCKET" --lifecycle-configuration \
  '{"Rules":[{"ID":"expire-after-90-days","Status":"Enabled","Filter":{},"Expiration":{"Days":90}}]}' >/dev/null
if aws cloudtrail get-trail --name "$TRAIL_NAME" --region "$REGION" >/dev/null 2>&1; then
  skip "trail $TRAIL_NAME exists"
else
  aws cloudtrail create-trail --name "$TRAIL_NAME" --s3-bucket-name "$TRAIL_BUCKET" --region "$REGION" \
    --is-multi-region-trail --include-global-service-events --enable-log-file-validation >/dev/null
  ok "created trail $TRAIL_NAME (all regions, log file validation on)"
fi
aws cloudtrail start-logging --name "$TRAIL_NAME" --region "$REGION"
ok "trail is logging to s3://$TRAIL_BUCKET (objects expire after 90 days)"

# ── 5. GitHub environment: production deploys only from main ──────────────────
# The role trusts "environment:production". That is only as strong as the rule
# for who may use that environment: without this, a workflow on any branch could
# name the environment and receive a token the role accepts.
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  if gh api -X PUT "repos/${REPO}/environments/production" \
       -F "deployment_branch_policy[protected_branches]=false" \
       -F "deployment_branch_policy[custom_branch_policies]=true" >/dev/null 2>&1; then
    gh api -X POST "repos/${REPO}/environments/production/deployment-branch-policies" \
       -f name=main -f type=branch >/dev/null 2>&1 || true      # already present on a re-run
    ok "GitHub environment 'production': deployments allowed from main only"
  else
    skip "could not configure the GitHub environment (check gh permissions); set it under Settings > Environments"
  fi
else
  skip "gh CLI not logged in: restrict the 'production' environment to main under Settings > Environments"
fi

# ── 6. Guardrail budget (optional) ────────────────────────────────────────────
if [[ -n "${BUDGET_EMAIL:-}" ]]; then
  if aws budgets describe-budget --account-id "$ACCOUNT_ID" --budget-name account-guardrail >/dev/null 2>&1; then
    skip "budget account-guardrail exists"
  else
    aws budgets create-budget --account-id "$ACCOUNT_ID" \
      --budget '{"BudgetName":"account-guardrail","BudgetLimit":{"Amount":"5","Unit":"USD"},"TimeUnit":"MONTHLY","BudgetType":"COST"}' \
      --notifications-with-subscribers "[{\"Notification\":{\"NotificationType\":\"ACTUAL\",\"ComparisonOperator\":\"GREATER_THAN\",\"Threshold\":80,\"ThresholdType\":\"PERCENTAGE\"},\"Subscribers\":[{\"SubscriptionType\":\"EMAIL\",\"Address\":\"${BUDGET_EMAIL}\"}]}]"
    ok "created budget account-guardrail (\$5/month, email at 80%)"
  fi
else
  skip "budget (set BUDGET_EMAIL to create one)"
fi

# ── 7. Copy app secrets from another account (optional, values never printed) ─
if [[ -n "${COPY_SECRETS_FROM:-}" ]]; then
  for name in "${SECRET_NAMES[@]}"; do
    if value="$(AWS_PROFILE="$COPY_SECRETS_FROM" aws ssm get-parameter --region "$REGION" --name "$name" \
                 --with-decryption --query Parameter.Value --output text 2>/dev/null)"; then
      aws ssm put-parameter --region "$REGION" --name "$name" --value "$value" \
        --type SecureString --overwrite >/dev/null
      ok "copied secret $name"
    else
      skip "secret $name not found in profile $COPY_SECRETS_FROM"
    fi
  done
  unset value
else
  skip "secret copy (set COPY_SECRETS_FROM=<profile> to copy them from another account)"
fi

# ── 8. Point the repo at this account ─────────────────────────────────────────
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
sed -i -E "s/(observeops-terraform-state-)[0-9]{12}/\1${ACCOUNT_ID}/" "$ROOT/terraform/main.tf"
ok "repo: terraform backend bucket is ${STATE_BUCKET}"

MISSING=()
for name in "${SECRET_NAMES[@]}"; do
  aws ssm get-parameter --region "$REGION" --name "$name" >/dev/null 2>&1 || MISSING+=("$name")
done

cat <<EOF

────────────────────────────────────────────────────────────────────
Baseline is in place for account ${ACCOUNT_ID}.

GitHub secret the pipeline needs (the others are set by scripts/infra-up.sh):
  gh secret set AWS_ROLE_ARN --repo ${REPO} --body "${ROLE_ARN}"
EOF
if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo ""
  echo "Secrets not yet in Parameter Store (create each one; the value is asked for, not echoed):"
  for name in "${MISSING[@]}"; do
    echo "  read -rs V && aws ssm put-parameter --type SecureString --name ${name} --value \"\$V\"; unset V"
  done
fi
cat <<EOF

Nothing that bills by the hour has been created. To bring the stack up:
  bash scripts/infra-up.sh
────────────────────────────────────────────────────────────────────
EOF
