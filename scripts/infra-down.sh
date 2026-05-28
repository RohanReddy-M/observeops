#!/usr/bin/env bash
# Tear down expensive AWS resources to stop billing.
# The Route53 hosted zone is intentionally kept alive (~₹42/month) to
# prevent DNS cache poisoning when infra is rebuilt — destroying and
# recreating the zone changes NS records which breaks DNS globally for days.
#
# ENV controls which environment to target (default: production)
# Usage: ENV=staging bash scripts/infra-down.sh
set -e

ENV="${ENV:-production}"
cd "$(dirname "$0")/../terraform"

terraform init -input=false -backend-config="key=${ENV}/terraform.tfstate" -reconfigure > /dev/null

echo "==> This will destroy all compute infrastructure (env: ${ENV}: EC2, ALB, NAT GW, VPC)."
echo "    Route53 hosted zone is kept to avoid DNS propagation issues."
read -p "    Type 'yes' to confirm: " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "Aborted."
  exit 0
fi

echo "==> Deleting ECR images to stop storage costs..."
for repo in observeops/secureship observeops/statusservice observeops/ragservice; do
  IMAGES=$(aws ecr list-images --region ap-south-1 --repository-name "$repo" --query 'imageIds' --output json 2>/dev/null)
  if [ "$IMAGES" != "[]" ] && [ -n "$IMAGES" ]; then
    aws ecr batch-delete-image --region ap-south-1 --repository-name "$repo" --image-ids "$IMAGES" > /dev/null
    echo "  Cleared $repo"
  fi
done

echo ""
echo "==> Destroying compute infrastructure (env: ${ENV})..."
# Destroy everything except the Route53 hosted zone and ACM cert/records
# (those live in module.alb but we target only the expensive parts)
terraform destroy -auto-approve -var-file="environments/${ENV}.tfvars" \
  -target=module.compute \
  -target=module.vpc \
  -target=module.security \
  -target=module.alb.aws_lb \
  -target=module.alb.aws_lb_listener.http \
  -target=module.alb.aws_lb_listener.https \
  -target=module.alb.aws_lb_target_group \
  -target=module.alb.aws_lb_target_group_attachment \
  -target=module.alb.aws_acm_certificate \
  -target=module.alb.aws_acm_certificate_validation \
  -target=module.alb.aws_route53_record.app \
  -target=module.alb.aws_route53_record.cert_validation

echo ""
echo "==> Clearing EC2_INSTANCE_ID GitHub secret so CI/CD skips deploy..."
gh secret set EC2_INSTANCE_ID --body "" --repo RohanReddy-M/observeops 2>/dev/null || true

echo "==> Billing stopped. Route53 zone kept (₹42/month — avoids DNS issues)."
echo "    Run scripts/infra-up.sh next time you need it live."
