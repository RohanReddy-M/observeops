#!/usr/bin/env bash
# Bring ObserveOps live — run this before an interview or job application.
# Takes about 8-10 minutes end to end.
#
# ENV controls which environment to target (default: production)
# Usage: ENV=staging bash scripts/infra-up.sh
set -e

ENV="${ENV:-production}"
cd "$(dirname "$0")/../terraform"

echo "==> Initialising Terraform (env: ${ENV})..."
terraform init -input=false -backend-config="key=${ENV}/terraform.tfstate"

echo "==> Creating infrastructure (env: ${ENV})..."
terraform apply -auto-approve -var-file="environments/${ENV}.tfvars"

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

echo ""
echo "==> Updating /etc/hosts so secureship.click works before DNS propagates..."
ALB_DNS=$(terraform output -raw alb_dns_name)
ALB_IP=$(python3 -c "import socket; print(socket.gethostbyname('${ALB_DNS}'))" 2>/dev/null || \
         getent hosts "${ALB_DNS}" | awk '{print $1; exit}' 2>/dev/null || echo "")
if [ -n "$ALB_IP" ]; then
    sudo sed -i '/secureship\.click/d' /etc/hosts 2>/dev/null || true
    echo "${ALB_IP} secureship.click" | sudo tee -a /etc/hosts > /dev/null
    echo "    secureship.click -> ${ALB_IP} (added to /etc/hosts)"
fi

echo "==> Triggering CI/CD deployment..."
cd ..
git commit --allow-empty -m "chore: trigger deploy after infra-up" && git push

echo ""
echo "==> Done! Wait ~8 minutes for EC2 bootstrap + CI/CD to finish."
echo "    Direct test (works now): curl -k https://${ALB_DNS}/health"
echo "    Domain (works after CI): curl https://secureship.click/health"
