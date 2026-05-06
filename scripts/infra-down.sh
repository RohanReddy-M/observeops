#!/usr/bin/env bash
# Tear down all AWS infrastructure to stop billing.
# Run this after your interview / when done applying.
# ECR images are deleted too — they get rebuilt on next infra-up.
set -e

cd "$(dirname "$0")/../terraform"

echo "==> This will destroy ALL AWS resources and stop all charges."
read -p "    Type 'yes' to confirm: " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "Aborted."
  exit 0
fi

echo "==> Destroying infrastructure..."
terraform destroy -auto-approve

echo ""
echo "==> All resources destroyed. Billing stopped."
echo "    Run scripts/infra-up.sh next time you need it live."
