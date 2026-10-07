#!/bin/bash
# ─── App Server Bootstrap ─────────────────────────────────────────────────────
# This script runs ONCE when the EC2 instance boots for the first time.
# AWS calls it "user data". It's how you automate server setup without SSH.
#
# After this runs the server is PREPARED: Docker, the repo, .env and a systemd
# unit. It deliberately does not start the application. The first CI deploy does,
# from the images CI built and pushed to ECR (scripts/infra-up.sh triggers it).
# This script used to `docker compose up` here, which built every image from
# source on first boot, including PyTorch on a 2 GB instance, racing the CI deploy
# that arrived a few minutes later.

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

# ── Pull Secrets from SSM Parameter Store ────────────────────────────────────
# NEVER hardcode secrets in user data - they appear in plain text in the
# AWS console and in any exported AMI. Use SSM Parameter Store instead.
# The EC2 IAM role may read parameters under /observeops/ and nothing else.
ssm_get() {   # ssm_get <full parameter name> [--with-decryption]
  aws ssm get-parameter --name "$1" --region ${aws_region} $2 \
    --query 'Parameter.Value' --output text 2>/dev/null || echo ""
}

# Retries, because some parameters are created by Terraform in the same apply that
# launches this instance and may appear a little after it boots.
ssm_wait() {  # ssm_wait <full parameter name> [--with-decryption]
  local value=""
  for _ in $(seq 1 24); do
    value=$(ssm_get "$1" "$2")
    [ -n "$value" ] && break
    sleep 5
  done
  echo "$value"
}

GROQ_API_KEY=$(ssm_get "/observeops/production/groq_api_key" --with-decryption)
SLACK_WEBHOOK_URL=$(ssm_get "/observeops/production/slack_webhook_critical" --with-decryption)
DYNAMODB_TABLE=$(ssm_get "/${project_name}/production/dynamodb_ships_table")
DYNAMODB_TABLE="$${DYNAMODB_TABLE:-${project_name}-ships}"

# The SecureShip API key. With DYNAMODB_TABLE set the service refuses to start
# without it, so wait for it rather than boot into a state that cannot serve.
SECURESHIP_API_KEY=$(ssm_wait "/${project_name}/production/secureship_api_key" --with-decryption)

# The observability server is created after this instance, so its address is
# usually not in SSM yet. If it is missing here, deploy.sh writes it on every
# deploy; until then "obs-server" falls back to this host.
OBS_SERVER_IP=$(ssm_wait "/${project_name}/production/obs_server_ip")

# Write the .env file that docker compose reads at startup
cat > /opt/observeops/.env <<EOF
ENVIRONMENT=production
GROQ_API_KEY=$${GROQ_API_KEY}
DYNAMODB_TABLE=$${DYNAMODB_TABLE}
SECURESHIP_API_KEY=$${SECURESHIP_API_KEY}
SLACK_WEBHOOK_URL=$${SLACK_WEBHOOK_URL}
AWS_DEFAULT_REGION=${aws_region}
EOF

if [ -n "$OBS_SERVER_IP" ]; then
  cat >> /opt/observeops/.env <<EOF
OBS_SERVER_IP=$${OBS_SERVER_IP}
LOKI_HOST=$${OBS_SERVER_IP}
LOKI_URL=http://$${OBS_SERVER_IP}:3100
GRAFANA_URL=http://$${OBS_SERVER_IP}:3000
EOF
fi

chmod 600 /opt/observeops/.env     # Only owner can read (secrets protection)
chown ubuntu:ubuntu /opt/observeops/.env

# ── Host metrics ──────────────────────────────────────────────────────────────
# The one container started at boot. It is a public image (nothing to build) and
# it means this host has CPU, memory and disk metrics from its first minute.
cd /opt/observeops
sudo -u ubuntu docker compose up -d --no-deps node-exporter

# ── Systemd Service for Auto-Start ───────────────────────────────────────────
# Without this, if the instance reboots, Docker starts but compose-managed
# containers may not come back in a known state. deploy.sh records the deployed
# ECR_REGISTRY and IMAGE_TAG in .env, so this brings back the same images that
# were deployed rather than rebuilding from whatever is checked out.
# --no-deps: Loki and Tempo are declared as dependencies in docker-compose.yml but
# they live on the observability server; without the flag they would start here.
cat > /etc/systemd/system/observeops-app.service <<'UNIT'
[Unit]
Description=ObserveOps Application Services
Requires=docker.service
After=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/observeops
ExecStart=/usr/bin/docker compose up -d --no-deps secureship statusservice ragservice nginx llm-alert-autopilot otel-collector promtail node-exporter
ExecStop=/usr/bin/docker compose stop secureship statusservice ragservice nginx llm-alert-autopilot otel-collector promtail node-exporter
User=ubuntu
Group=ubuntu

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable observeops-app

echo "=== Bootstrap complete: $(date) ==="
echo "Host prepared. The application starts on the first CI deploy."
