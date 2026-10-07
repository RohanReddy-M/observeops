#!/usr/bin/env bash
# Bring ObserveOps up on AWS and deploy to it. About 15 minutes end to end.
#
#   bash scripts/infra-up.sh              # production
#   ENV=staging bash scripts/infra-up.sh
#
# What it does, in order:
#   1. terraform apply                       (VPC, 2 EC2, ALB, DynamoDB, Lambda, ECR ...)
#   2. waits for both instances to finish their first-boot bootstrap
#   3. points the GitHub Actions secrets at the new instance and registry
#   4. pushes an empty commit, which makes CI build the images and deploy them
#
# Cost while it is up: roughly $0.12 an hour (NAT gateway, ALB, two t3.small).
# Run scripts/infra-down.sh when you are done. Nothing is billed while it is down.
#
# Requirements: terraform, aws CLI (credentials for the account), gh CLI (logged in),
# and terraform/terraform.tfvars containing admin_cidr = "<your ip>/32".
set -euo pipefail

ENV="${ENV:-production}"
REPO="${REPO:-RohanReddy-M/observeops}"
REGION="${AWS_REGION:-ap-south-1}"
export AWS_DEFAULT_REGION="$REGION"
# Git Bash on Windows rewrites arguments that start with "/" into Windows paths
# before they reach a native exe, which mangles SSM parameter names.
export MSYS_NO_PATHCONV=1

cd "$(dirname "$0")/../terraform"

echo "==> Initialising Terraform (env: ${ENV})..."
terraform init -input=false -reconfigure -backend-config="key=${ENV}/terraform.tfstate" > /dev/null

DOMAIN=$(grep -E '^\s*domain_name\s*=' terraform.tfvars "environments/${ENV}.tfvars" 2>/dev/null \
         | tail -1 | sed -E 's/.*=\s*"([^"]*)".*/\1/' || true)

if [ -n "${DOMAIN:-}" ]; then
    # With a domain, the certificate can only validate once the registrar delegates
    # to the hosted zone Terraform creates. So: create the zone alone, point the
    # registrar at it, and only then apply the rest (which waits on validation).
    echo "==> Domain mode (${DOMAIN}): creating the hosted zone first..."
    terraform apply -auto-approve -input=false -var-file="environments/${ENV}.tfvars" \
        -target='module.alb.aws_route53_zone.main'
    NS=$(terraform output -json route53_name_servers | tr -d '[]" 
' | tr ',' '
' | sed 's/^/Name=/' | tr '
' ' ')
    echo "==> Pointing the registrar at the new zone's name servers..."
    # shellcheck disable=SC2086
    aws route53domains update-domain-nameservers --region us-east-1 \
        --domain-name "$DOMAIN" --nameservers $NS > /dev/null \
        || echo "    !! Could not update name servers automatically. Set them by hand at the registrar: $NS"
else
    echo "==> No domain configured: the ALB will serve HTTP on its own AWS DNS name."
fi

echo "==> Creating infrastructure (env: ${ENV})..."
terraform apply -auto-approve -input=false -var-file="environments/${ENV}.tfvars"

APP_ID=$(terraform output -raw app_instance_id)
OBS_ID=$(terraform output -raw obs_instance_id)
PUBLIC_URL=$(terraform output -raw live_url)
ECR_URL="$(terraform output -raw ecr_secureship_url | cut -d'/' -f1)/observeops"

# ── Wait for first boot to finish ────────────────────────────────────────────
# CI deploys by sending an SSM command to the app server. If that arrives while
# user_data is still installing Docker, the deploy fails for a reason that has
# nothing to do with the code. So wait until each instance is registered with SSM
# and cloud-init reports done, and only then trigger CI.
wait_for_boot() {   # wait_for_boot <instance-id> <label>
    local id="$1" label="$2" cmd status
    echo "==> Waiting for ${label} (${id}) to register with SSM..."
    for _ in $(seq 1 60); do
        if [ "$(aws ssm describe-instance-information \
                --filters "Key=InstanceIds,Values=${id}" \
                --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null)" = "Online" ]; then
            break
        fi
        sleep 10
    done
    echo "==> Waiting for ${label} bootstrap (cloud-init) to finish..."
    cmd=$(aws ssm send-command --instance-ids "$id" --document-name AWS-RunShellScript \
            --parameters 'commands=["cloud-init status --wait > /dev/null 2>&1; cloud-init status; tail -n 3 /var/log/user-data.log"]' \
            --query 'Command.CommandId' --output text)
    for _ in $(seq 1 90); do
        status=$(aws ssm get-command-invocation --command-id "$cmd" --instance-id "$id" \
                   --query 'Status' --output text 2>/dev/null || echo Pending)
        case "$status" in
            Success) aws ssm get-command-invocation --command-id "$cmd" --instance-id "$id" \
                         --query 'StandardOutputContent' --output text | sed 's/^/    /'; return 0 ;;
            Failed|Cancelled|TimedOut)
                     echo "    !! ${label} bootstrap check ended with: ${status}"
                     aws ssm get-command-invocation --command-id "$cmd" --instance-id "$id" \
                         --query 'StandardOutputContent' --output text | sed 's/^/    /'; return 1 ;;
        esac
        sleep 10
    done
    echo "    !! timed out waiting for ${label}"; return 1
}

wait_for_boot "$APP_ID" "app server"
wait_for_boot "$OBS_ID" "observability server"

echo "==> Pointing GitHub Actions at the new infrastructure..."
gh secret set EC2_INSTANCE_ID --repo "$REPO" --body "$APP_ID"
gh secret set ECR_REGISTRY    --repo "$REPO" --body "$ECR_URL"

echo "==> Triggering the CI/CD deployment..."
cd ..
git pull --rebase --quiet
git commit --allow-empty -m "chore: trigger deploy after infra-up" --quiet
git push --quiet

echo ""
echo "==> Infrastructure is up. CI is now building and deploying (about 8 minutes)."
echo "    Watch it:   gh run watch --repo ${REPO}"
echo "    Then open:  ${PUBLIC_URL}/"
echo "                ${PUBLIC_URL}/grafana/       (admin / observeops123)"
echo "    Tear down:  bash scripts/infra-down.sh"
