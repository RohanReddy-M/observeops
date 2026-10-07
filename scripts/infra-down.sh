#!/usr/bin/env bash
# Tear ObserveOps down and stop all billing.
#
#   bash scripts/infra-down.sh          # asks for confirmation
#   bash scripts/infra-down.sh --yes    # no prompt (CI, scripts)
#   ENV=staging bash scripts/infra-down.sh
#
# This destroys EVERYTHING Terraform created for the environment: both EC2
# instances, the ALB, the NAT gateway, the VPC, DynamoDB, both Lambdas, the ECR
# repositories and their images. Nothing is left running and nothing is billed.
# What survives is what lives outside this stack: the Terraform state bucket and
# lock table, the GitHub OIDC provider and role, and the secrets you put in SSM.
#
# An earlier version used a list of -target flags to keep the Route 53 zone. That
# list silently skipped everything not named in it (DynamoDB, Lambda, ECR, the
# schedule that invoked a Lambda every five minutes), so "down" left a partial
# stack behind.
set -euo pipefail

ENV="${ENV:-production}"
REPO="${REPO:-RohanReddy-M/observeops}"
REGION="${AWS_REGION:-ap-south-1}"
export AWS_DEFAULT_REGION="$REGION"
export MSYS_NO_PATHCONV=1

cd "$(dirname "$0")/../terraform"
terraform init -input=false -reconfigure -backend-config="key=${ENV}/terraform.tfstate" > /dev/null

if [ "${1:-}" != "--yes" ] && [ "${1:-}" != "-y" ]; then
    echo "==> This will destroy ALL infrastructure for env '${ENV}'."
    read -r -p "    Type 'yes' to confirm: " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo "Aborted."
        exit 0
    fi
fi

# Tell CI the infrastructure is gone BEFORE destroying it, so a push that lands
# mid-teardown skips the build and deploy jobs instead of failing against
# resources that are disappearing (deploy.yml's check-aws job reads this secret).
echo "==> Clearing EC2_INSTANCE_ID so CI skips build and deploy..."
gh secret set EC2_INSTANCE_ID --repo "$REPO" --body "" 2>/dev/null || true

echo "==> Destroying infrastructure (env: ${ENV})..."
terraform destroy -auto-approve -input=false -var-file="environments/${ENV}.tfvars"

echo ""
echo "==> Verifying nothing billable is left in ${REGION}..."
LEFT=0
check() {   # check <label> <count>
    if [ "$2" != "0" ] && [ -n "$2" ] && [ "$2" != "None" ]; then
        echo "    !! ${1}: ${2} still present"; LEFT=1
    else
        echo "    ok  ${1}: none"
    fi
}
check "EC2 instances"   "$(aws ec2 describe-instances --filters 'Name=instance-state-name,Values=pending,running,stopping,stopped' --query 'length(Reservations[].Instances[])' --output text)"
check "NAT gateways"    "$(aws ec2 describe-nat-gateways --filter 'Name=state,Values=pending,available,deleting' --query 'length(NatGateways)' --output text)"
check "Load balancers"  "$(aws elbv2 describe-load-balancers --query 'length(LoadBalancers)' --output text)"
check "Elastic IPs"     "$(aws ec2 describe-addresses --query 'length(Addresses)' --output text)"
check "EBS volumes"     "$(aws ec2 describe-volumes --query 'length(Volumes)' --output text)"

if [ "$LEFT" = "1" ]; then
    echo "==> Something is still present. Check it in the console before assuming billing has stopped."
    exit 1
fi
echo "==> Down. Nothing billable remains. Run scripts/infra-up.sh to bring it back."
