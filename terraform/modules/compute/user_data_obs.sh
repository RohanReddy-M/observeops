#!/bin/bash
# ─── Observability Server Bootstrap ──────────────────────────────────────────
# This server runs Prometheus, Grafana, Loki, AlertManager, Promtail.
# It is intentionally separate from the app server: if the app has a
# resource problem (high CPU/memory), monitoring stays unaffected.
#
# The app_server_ip variable is injected by Terraform's templatefile() function.

set -e

exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

echo "=== ObserveOps Observability Server Bootstrap ==="
echo "Started: $(date)"
echo "Monitoring app server at: ${app_server_ip}"

# ── System Packages ───────────────────────────────────────────────────────────
apt-get update -y
apt-get install -y curl git jq unzip net-tools htop

# ── Docker ────────────────────────────────────────────────────────────────────
curl -fsSL https://get.docker.com | sh
usermod -aG docker ubuntu
systemctl enable docker
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

# ── Pull Configuration ────────────────────────────────────────────────────────
cd /opt/observeops
git clone https://github.com/RohanReddy-M/observeops.git .
chown -R ubuntu:ubuntu /opt/observeops

# ── Environment ───────────────────────────────────────────────────────────────
# No config file is edited here. prometheus.yml and alertmanager.yml refer to the
# application host as "app-server"; docker-compose maps that name to APP_SERVER_IP
# through extra_hosts. The same files therefore run unchanged on a laptop, where
# the variable is unset and the name falls back to the Docker host.
cat > /opt/observeops/.env <<EOF
APP_SERVER_IP=${app_server_ip}
PUBLIC_BASE_URL=${public_base_url}
AWS_DEFAULT_REGION=${aws_region}
EOF
chmod 600 /opt/observeops/.env
chown ubuntu:ubuntu /opt/observeops/.env

# ── AlertManager secrets ──────────────────────────────────────────────────────
# Webhook URLs are read by AlertManager from files (api_url_file / url_file), so
# they never touch the tracked config. A missing parameter leaves the file absent;
# AlertManager then logs a notify error for that receiver instead of failing.
SECRETS_DIR=/opt/observeops/monitoring/alertmanager/secrets
mkdir -p "$SECRETS_DIR"

write_secret() {   # write_secret <ssm name under /observeops/production/> <file name>
  local value
  value=$(aws ssm get-parameter --name "/observeops/production/$1" --with-decryption \
    --region ${aws_region} --query 'Parameter.Value' --output text 2>/dev/null || echo "")
  if [ -n "$value" ]; then
    printf '%s' "$value" > "$SECRETS_DIR/$2"
    echo "wrote secret file: $2"
  else
    echo "SSM parameter $1 not found - $2 not written"
  fi
}

write_secret slack_webhook_critical slack_webhook_critical
write_secret slack_webhook_warnings slack_webhook_warnings
write_secret healthchecks_url       healthchecks_url        # deadman switch; optional

# The AlertManager image runs as nobody (65534): make the files readable by it and
# by nothing else.
chown -R 65534:65534 "$SECRETS_DIR"
chmod 500 "$SECRETS_DIR"
find "$SECRETS_DIR" -type f ! -name README.md -exec chmod 400 {} +

# ── Start Monitoring Services ─────────────────────────────────────────────────
cd /opt/observeops
sudo -u ubuntu docker compose up -d prometheus grafana loki promtail alertmanager node-exporter tempo

# ── Systemd Service for Auto-Start ───────────────────────────────────────────
cat > /etc/systemd/system/observeops-monitoring.service <<'UNIT'
[Unit]
Description=ObserveOps Monitoring Services
Requires=docker.service
After=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/observeops
ExecStart=/usr/bin/docker compose up -d prometheus grafana loki promtail alertmanager node-exporter tempo
ExecStop=/usr/bin/docker compose stop prometheus grafana loki promtail alertmanager node-exporter tempo
User=ubuntu
Group=ubuntu

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable observeops-monitoring

echo "=== Obs Server Bootstrap complete: $(date) ==="
echo "Grafana:    http://$(hostname -I | awk '{print $1}'):3000  (admin/observeops123)"
echo "Prometheus: http://$(hostname -I | awk '{print $1}'):9090"
