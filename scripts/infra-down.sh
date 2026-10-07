#!/usr/bin/env bash
# Tear ObserveOps down and stop everything that bills by the hour.
#
#   bash scripts/infra-down.sh          # asks for confirmation
#   bash scripts/infra-down.sh --yes    # no prompt
#   ENV=staging bash scripts/infra-down.sh
#
# This destroys EVERYTHING Terraform created for the environment: both EC2
# instances, the load balancer, the NAT gateway, the VPC, the DynamoDB table and
# its data, both Lambdas, the ECR repositories and their images, and the
# generated API key and Grafana password.
#
# What stays, on purpose, is the account baseline made by
# scripts/bootstrap-aws-account.sh: the Terraform state bucket, the CloudTrail
# trail and its bucket, the GitHub OIDC provider and CI role, and the secrets you
# put in Parameter Store yourself. Together they cost a few cents a month.
#
# An earlier version used a list of -target flags to keep the Route 53 zone. That
# list silently skipped everything not named in it (DynamoDB, Lambda, ECR, the
# schedule that invoked a Lambda every five minutes), so "down" left a partial
# stack behind. `terraform destroy` with no targets cannot forget anything.
#
# If this script itself is interrupted (closed terminal, lost network) partway through,
# the state lock can be left held. Clear it before running this again:
#   aws s3 rm s3://observeops-terraform-state-<account-id>/production/terraform.tfstate.tflock
# Then re-run. The check at the end of this script runs even when `terraform destroy` itself
# reports an error, which is what caught this the one time it happened (a DNS failure mid-destroy).
set -euo pipefail

ENV="${ENV:-production}"
REPO="${REPO:-RohanReddy-M/observeops}"
REGION="${AWS_REGION:-ap-south-1}"
export AWS_DEFAULT_REGION="$REGION"
export AWS_PAGER=""
export MSYS_NO_PATHCONV=1
# The AWS CLI is Python. On a Windows console its output encoding is cp1252, and
# the server's logs contain arrows (symlink lines). Without this the CLI crashes
# printing a boot log, mid-run, after the work has succeeded.
export PYTHONUTF8=1 PYTHONIOENCODING=utf-8

cd "$(dirname "$0")/../terraform"
terraform init -input=false -reconfigure -backend-config="key=${ENV}/terraform.tfstate" > /dev/null

if [ "${1:-}" != "--yes" ] && [ "${1:-}" != "-y" ]; then
    echo "==> This will destroy ALL infrastructure for env '${ENV}', including the data in DynamoDB."
    read -r -p "    Type 'yes' to confirm: " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo "Aborted."
        exit 0
    fi
fi

# Tell CI the stack is gone BEFORE destroying it, so a push that lands during or
# after the teardown skips the build and deploy jobs instead of failing against
# resources that no longer exist (the check-aws job looks for this secret).
echo "==> Removing EC2_INSTANCE_ID so CI skips build and deploy..."
gh secret delete EC2_INSTANCE_ID --repo "$REPO" 2>/dev/null || true

echo "==> Destroying infrastructure (env: ${ENV}, about 6 minutes)..."
# Not `set -e` for this one line: a destroy that fails (a timeout, a transient network
# error while Terraform saves state) must not skip the check below. That check is the
# whole point of this script -- it is what catches a partial teardown -- so it has to run
# whether or not Terraform thinks it succeeded. Found for real on 7 Oct 2026: a DNS blip
# mid-destroy ended the script here under `set -e`, and an EC2 instance and a load balancer
# stayed up, unnoticed, until a manual check found them.
DESTROY_OK=1
terraform destroy -auto-approve -input=false -var-file="environments/${ENV}.tfvars" || DESTROY_OK=0
if [ "$DESTROY_OK" = "0" ]; then
    echo ""
    echo "!! terraform destroy reported an error (see above). Checking anyway what is actually left,"
    echo "   because the state file may no longer match reality. If it ran out of a lock or a network"
    echo "   error, re-run this script: bash scripts/infra-down.sh --yes"
fi

echo ""
echo "==> Checking that nothing which bills by the hour is left in ${REGION}..."
LEFT=0
check() {   # check <label> <count>
    if [ "$2" != "0" ] && [ -n "$2" ] && [ "$2" != "None" ]; then
        echo "    !! ${1}: ${2} still present"; LEFT=1
    else
        echo "    ok  ${1}: none"
    fi
}
check "EC2 instances"     "$(aws ec2 describe-instances --filters 'Name=instance-state-name,Values=pending,running,stopping,stopped' --query 'length(Reservations[].Instances[])' --output text)"
check "NAT gateways"      "$(aws ec2 describe-nat-gateways --filter 'Name=state,Values=pending,available,deleting' --query 'length(NatGateways)' --output text)"
check "Load balancers"    "$(aws elbv2 describe-load-balancers --query 'length(LoadBalancers)' --output text)"
check "Elastic IPs"       "$(aws ec2 describe-addresses --query 'length(Addresses)' --output text)"
check "EBS volumes"       "$(aws ec2 describe-volumes --query 'length(Volumes)' --output text)"
check "Non-default VPCs"  "$(aws ec2 describe-vpcs --query 'length(Vpcs[?IsDefault==`false`])' --output text)"
check "ECR repositories"  "$(aws ecr describe-repositories --query 'length(repositories)' --output text)"
check "Lambda functions"  "$(aws lambda list-functions --query 'length(Functions[?starts_with(FunctionName, `observeops`)])' --output text)"
check "Project log groups" "$(aws logs describe-log-groups --log-group-name-prefix /aws/lambda/observeops --query 'length(logGroups)' --output text)"

if [ "$LEFT" = "1" ]; then
    echo ""
    echo "==> Something is still present. Look at it in the console before assuming billing has stopped."
    exit 1
fi
echo ""
echo "==> Down. Nothing that bills by the hour remains."
echo "    Still in the account, by design: the state bucket, the CloudTrail trail and bucket,"
echo "    the CI role, and your Parameter Store secrets (cents per month)."
echo "    Bring it back with: bash scripts/infra-up.sh"
