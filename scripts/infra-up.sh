#!/usr/bin/env bash
# Bring ObserveOps live — run this before an interview or job application.
# Takes about 10-12 minutes end to end.
set -e

cd "$(dirname "$0")/../terraform"

echo "==> Phase 1: Create Route53 hosted zone first..."
# Create the zone BEFORE the full apply so we can update NS records
# before ACM tries to validate (ACM validation needs correct NS to work).
terraform apply -target=module.alb.aws_route53_zone.main -auto-approve

echo ""
echo "==> Syncing nameservers to domain registrar..."
NAMESERVERS=$(terraform output -json route53_name_servers | jq -r '.[] | "Name=\(.)"' | tr '\n' ' ')
aws route53domains update-domain-nameservers \
  --region us-east-1 \
  --domain-name secureship.click \
  --nameservers $NAMESERVERS
echo "==> Nameservers updated. Waiting 30s for propagation..."
sleep 30

echo ""
echo "==> Phase 2: Apply all remaining infrastructure..."
terraform apply -auto-approve

echo ""
echo "==> Updating GitHub secrets with new instance ID..."
INSTANCE_ID=$(aws ec2 describe-instances \
  --region ap-south-1 \
  --filters "Name=private-ip-address,Values=$(terraform output -raw app_server_private_ip)" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
gh secret set EC2_INSTANCE_ID --repo RohanReddy-M/observeops --body "$INSTANCE_ID"

ECR_URL=$(terraform output -raw ecr_secureship_url | cut -d'/' -f1)/observeops
gh secret set ECR_REGISTRY --repo RohanReddy-M/observeops --body "$ECR_URL"

echo "==> Triggering CI/CD deployment..."
cd ..
git commit --allow-empty -m "chore: trigger deploy after infra-up" && git push

echo ""
echo "==> Done! Wait ~8 minutes for EC2 bootstrap + CI/CD to finish."
echo "    Live at: https://secureship.click"
