#!/bin/bash
# ─── App Server Bootstrap ─────────────────────────────────────────────────────
# This script runs ONCE when the EC2 instance boots for the first time.
# AWS calls it "user data". It's how you automate server setup without SSH.
#
# After this runs, the server is fully configured and services are running.
# You should never need to SSH in for routine operations.

set -e

# Redirect all output to a log file AND to the system journal.
# If something breaks, you can read /var/log/user-data.log to diagnose.
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

echo "=== ObserveOps App Server Bootstrap ==="
echo "Started: $(date)"

# ── System Packages ───────────────────────────────────────────────────────────
apt-get update -y
apt-get install -y curl git jq unzip net-tools htop

# ── Docker ────────────────────────────────────────────────────────────────────
# get.docker.com is the official installer. It detects Ubuntu and installs
# the correct version of Docker Engine + Docker Compose plugin.
curl -fsSL https://get.docker.com | sh
usermod -aG docker ubuntu     # Allow ubuntu user to run docker without sudo
systemctl enable docker       # Start on every reboot
systemctl start docker

# ── AWS CLI v2 ────────────────────────────────────────────────────────────────
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp/
/tmp/aws/install
rm -rf /tmp/awscliv2.zip /tmp/aws

# ── Directory Structure ───────────────────────────────────────────────────────
mkdir -p /opt/observeops
mkdir -p /var/log/observeops
chown -R ubuntu:ubuntu /opt/observeops /var/log/observeops

# ── Pull Application Code ─────────────────────────────────────────────────────
# Clone the repo so we have docker-compose.yml and all config files
cd /opt/observeops
git clone https://github.com/RohanReddy-M/observeops.git .
chown -R ubuntu:ubuntu /opt/observeops

# Clone the LLM Alert Autopilot (separate repo, needed for AI diagnosis)
git clone https://github.com/RohanReddy-M/llm-alert-autopilot.git /opt/llm-alert-autopilot
chown -R ubuntu:ubuntu /opt/llm-alert-autopilot

# ── Pull Secrets from SSM Parameter Store ────────────────────────────────────
# NEVER hardcode secrets in user data - they appear in plain text in the
# AWS console and in any exported AMI. Use SSM Parameter Store instead.
# The EC2 IAM role has permission to read this specific parameter.
GROQ_API_KEY=$(aws ssm get-parameter \
  --name "/observeops/production/groq_api_key" \
  --with-decryption \
  --region ${aws_region} \
  --query 'Parameter.Value' \
  --output text 2>/dev/null || echo "")

DYNAMODB_TABLE=$(aws ssm get-parameter \
  --name "/${project_name}/production/dynamodb_ships_table" \
  --region ${aws_region} \
  --query 'Parameter.Value' \
  --output text 2>/dev/null || echo "${project_name}-ships")

SLACK_WEBHOOK_URL=$(aws ssm get-parameter \
  --name "/observeops/production/slack_webhook_critical" \
  --with-decryption \
  --region ${aws_region} \
  --query 'Parameter.Value' \
  --output text 2>/dev/null || echo "")

# Write the .env file that docker-compose reads at startup
cat > /opt/observeops/.env <<EOF
GROQ_API_KEY=$${GROQ_API_KEY}
DYNAMODB_TABLE=$${DYNAMODB_TABLE}
SLACK_WEBHOOK_URL=$${SLACK_WEBHOOK_URL}
AWS_DEFAULT_REGION=${aws_region}
EOF

chmod 600 /opt/observeops/.env     # Only owner can read (secrets protection)
chown ubuntu:ubuntu /opt/observeops/.env

# ── Start App Services ────────────────────────────────────────────────────────
# The observability services run on the other server.
# Here we only start what serves user traffic.
cd /opt/observeops
# promtail starts here but will use container name 'loki' until the first CI deploy
# injects LOKI_HOST=<obs_private_ip> into .env and force-recreates the container.
sudo -u ubuntu docker compose up -d secureship statusservice ragservice nginx llm-alert-autopilot promtail

# ── Systemd Service for Auto-Start ───────────────────────────────────────────
# Without this, if the instance reboots, Docker starts but containers don't.
# This systemd unit starts our containers on every boot, after Docker is ready.
cat > /etc/systemd/system/observeops-app.service <<'UNIT'
[Unit]
Description=ObserveOps Application Services
Requires=docker.service
After=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/observeops
ExecStart=/usr/bin/docker compose up -d secureship statusservice ragservice nginx llm-alert-autopilot promtail
ExecStop=/usr/bin/docker compose stop secureship statusservice ragservice nginx llm-alert-autopilot promtail
User=ubuntu
Group=ubuntu

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable observeops-app

echo "=== Bootstrap complete: $(date) ==="
echo "Services started. Check: docker ps"
