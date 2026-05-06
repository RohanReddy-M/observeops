#!/usr/bin/env bash
# Bring ObserveOps live — run this before an interview or job application.
# Takes about 8-10 minutes end to end.
set -e

cd "$(dirname "$0")/../terraform"

echo "==> Creating infrastructure..."
terraform apply -auto-approve

echo ""
echo "==> Syncing Route53 nameservers to domain registrar..."
# Route53 creates a new hosted zone with new NS records each apply.
# Must update domain registration to point to the new NS. Domains API is always us-east-1.
NAMESERVERS=$(terraform output -json route53_name_servers | jq -r '.[] | "Name=\(.)"' | tr '\n' ' ')
aws route53domains update-domain-nameservers \
  --region us-east-1 \
  --domain-name secureship.click \
  --nameservers $(echo $NAMESERVERS)
echo "==> Nameservers updated. DNS propagation usually takes 2-10 minutes."

echo ""
echo "==> Updating GitHub secrets with new instance ID..."
INSTANCE_ID=$(terraform output -raw app_server_private_ip | xargs -I{} aws ec2 describe-instances \
  --region ap-south-1 \
  --filters "Name=private-ip-address,Values={}" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
gh secret set EC2_INSTANCE_ID --repo RohanReddy-M/observeops --body "$INSTANCE_ID"

ECR_URL=$(terraform output -raw ecr_secureship_url | cut -d'/' -f1)/observeops
gh secret set ECR_REGISTRY --repo RohanReddy-M/observeops --body "$ECR_URL"

echo "==> Triggering deployment..."
cd ..
git commit --allow-empty -m "chore: trigger deploy after infra-up" && git push

echo ""
echo "==> Done! Wait ~5 minutes for EC2 bootstrap + CI/CD deploy to finish."
echo "    Live at: https://secureship.click"
