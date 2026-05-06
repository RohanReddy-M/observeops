#!/usr/bin/env bash
# Bring ObserveOps live — run this before an interview or job application.
# Takes about 8-10 minutes end to end.
set -e

cd "$(dirname "$0")/../terraform"

echo "==> Creating infrastructure..."
terraform apply -auto-approve

echo ""
echo "==> Infrastructure ready. Updating GitHub secrets with new IPs..."

APP_IP=$(terraform output -raw app_server_private_ip)
ECR_URL=$(terraform output -raw ecr_secureship_url | cut -d'/' -f1)

gh secret set EC2_APP_HOST --repo RohanReddy-M/observeops --body "$APP_IP"
gh secret set ECR_REGISTRY  --repo RohanReddy-M/observeops --body "$ECR_URL"

echo "==> Triggering deployment..."
cd ..
git commit --allow-empty -m "chore: trigger deploy after infra-up" && git push

echo ""
echo "==> Done! Wait ~5 minutes for EC2 bootstrap + CI/CD deploy to finish."
echo "    Live at: https://secureship.click"
