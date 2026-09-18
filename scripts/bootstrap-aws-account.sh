#!/usr/bin/env bash
# ─── Bootstrap a fresh AWS account for ObserveOps ────────────────────────────
# Creates only the cheap, foundational pieces that must exist BEFORE
# `terraform apply` or a GitHub Actions deploy can work in a new account:
#
#   1. Terraform remote-state bucket   observeops-terraform-state-<account-id>
#      (versioned, AES256-encrypted, all public access blocked)
#   2. Terraform lock table            observeops-terraform-locks (on-demand)
#   3. GitHub Actions OIDC provider    token.actions.githubusercontent.com
#   4. GitHub Actions deploy role      observeops-github-actions
#      (trust scoped to repo:RohanReddy-M/observeops:*; same permissions as before)
#   5. Optional guardrail budget       account-guardrail, $5/month, email at 80%
#   6. Optional copy of app secrets    /observeops/production/* from another profile
#   7. Repo updates                    backend bucket name + K8s image registry
#
# It does NOT create the application stack (VPC, EC2, NAT, ALB...). That is
# `terraform apply`, which costs money and is a separate decision.
#
# Every step is idempotent: re-running skips anything that already exists.
#
# Usage (Git Bash, from the repo root):
#   AWS_PROFILE=observeops-new bash scripts/bootstrap-aws-account.sh
#   AWS_PROFILE=observeops-new BUDGET_EMAIL=you@example.com \
#     COPY_SECRETS_FROM=default bash scripts/bootstrap-aws-account.sh
set -euo pipefail
export AWS_PAGER=""
# Git Bash rewrites arguments that start with "/" into Windows paths before they
# reach a native exe, which turns SSM names like /observeops/production/x into
# C:/Program Files/Git/observeops/... Turn that conversion off for this script.
export MSYS_NO_PATHCONV=1

REGION="${AWS_REGION:-ap-south-1}"
REPO="RohanReddy-M/observeops"
ROLE_NAME="observeops-github-actions"
LOCK_TABLE="observeops-terraform-locks"
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

# ── 0. Who am I? Refuse to run against the wrong account by accident ──────────
[[ -n "${AWS_PROFILE:-}" ]] || { echo "Set AWS_PROFILE to the NEW account's profile (e.g. AWS_PROFILE=observeops-new)."; exit 1; }
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
CALLER="$(aws sts get-caller-identity --query Arn --output text)"
log "Profile $AWS_PROFILE -> account $ACCOUNT_ID ($CALLER), region $REGION"
if [[ -n "${COPY_SECRETS_FROM:-}" ]]; then
  SRC_ACCOUNT="$(AWS_PROFILE="$COPY_SECRETS_FROM" aws sts get-caller-identity --query Account --output text)"
  [[ "$SRC_ACCOUNT" != "$ACCOUNT_ID" ]] || { echo "COPY_SECRETS_FROM points at the same account ($ACCOUNT_ID). Nothing to copy."; exit 1; }
fi
read -r -p "Bootstrap account $ACCOUNT_ID? [y/N] " ans; [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }

BUCKET="observeops-terraform-state-${ACCOUNT_ID}"

# ── 1. State bucket ───────────────────────────────────────────────────────────
if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  skip "state bucket $BUCKET exists"
else
  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
  ok "created state bucket $BUCKET"
fi
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
ok "state bucket: versioning on, encrypted, public access blocked"

# ── 2. Lock table ─────────────────────────────────────────────────────────────
if aws dynamodb describe-table --table-name "$LOCK_TABLE" --region "$REGION" >/dev/null 2>&1; then
  skip "lock table $LOCK_TABLE exists"
else
  aws dynamodb create-table --table-name "$LOCK_TABLE" --region "$REGION" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST >/dev/null
  aws dynamodb wait table-exists --table-name "$LOCK_TABLE" --region "$REGION"
  ok "created lock table $LOCK_TABLE"
fi

# ── 3. GitHub OIDC provider ───────────────────────────────────────────────────
PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${GH_OIDC_URL}"
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$PROVIDER_ARN" >/dev/null 2>&1; then
  skip "OIDC provider exists"
else
  aws iam create-open-id-connect-provider --url "https://${GH_OIDC_URL}" \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 1c58a3a8518e8759bf075b76b750d4f2df264fcd >/dev/null
  ok "created GitHub OIDC provider"
fi

# ── 4. Deploy role (same trust + permissions as the old account's role) ───────
cat > "$TMP_DIR/trust.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "${PROVIDER_ARN}" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": { "${GH_OIDC_URL}:aud": "sts.amazonaws.com" },
      "StringLike":   { "${GH_OIDC_URL}:sub": "repo:${REPO}:*" }
    }
  }]
}
EOF
cat > "$TMP_DIR/ec2-describe.json" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{ "Effect": "Allow", "Action": ["ec2:DescribeInstances", "ec2:DescribeTags"], "Resource": "*" }]
}
EOF
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "$(file_uri "$TMP_DIR/trust.json")"
  skip "role $ROLE_NAME exists (trust policy refreshed)"
else
  aws iam create-role --role-name "$ROLE_NAME" \
    --description "GitHub Actions deploy role for ${REPO} (OIDC, no static keys)" \
    --assume-role-policy-document "$(file_uri "$TMP_DIR/trust.json")" >/dev/null
  ok "created role $ROLE_NAME"
fi
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/AmazonSSMFullAccess
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name ec2-describe-readonly \
  --policy-document "$(file_uri "$TMP_DIR/ec2-describe.json")"
ROLE_ARN="$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text)"
ok "role permissions: SSM, ECR power user, EC2 describe"

# ── 5. Guardrail budget (optional) ────────────────────────────────────────────
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

# ── 6. Copy app secrets from the old account (optional, values never printed) ─
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
  skip "secrets (set COPY_SECRETS_FROM=<old profile> to copy them)"
fi

# ── 7. Point the repo at the new account ──────────────────────────────────────
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
sed -i -E "s/(observeops-terraform-state-)[0-9]{12}/\1${ACCOUNT_ID}/" "$ROOT/terraform/main.tf"
sed -i -E "s/[0-9]{12}(\.dkr\.ecr\.)/${ACCOUNT_ID}\1/" "$ROOT"/kubernetes/apps/*/deployment.yaml
ok "repo: terraform backend + K8s image registry now use account $ACCOUNT_ID"

cat <<EOF

────────────────────────────────────────────────────────────────────
Bootstrap complete for account ${ACCOUNT_ID}.

GitHub secrets to update:
  AWS_ROLE_ARN = ${ROLE_ARN}
  ECR_REGISTRY = ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com

  gh secret set AWS_ROLE_ARN --body "${ROLE_ARN}"
  gh secret set ECR_REGISTRY --body "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

Terraform must re-initialise against the new, empty state bucket:
  cd terraform && terraform init -reconfigure

Nothing that costs money has been deployed. Bringing the stack up is:
  terraform apply   (decide first: NAT Gateway + EC2 + ALB bill by the hour)
────────────────────────────────────────────────────────────────────
EOF
