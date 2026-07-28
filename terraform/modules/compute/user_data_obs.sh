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

# ── Point Prometheus at the App Server ───────────────────────────────────────
# prometheus.yml uses __APP_SERVER_IP__ placeholders for targets that live on
# the app server. Replace them with the actual private IP passed from Terraform.
APP_IP="${app_server_ip}"

sed -i "s|__APP_SERVER_IP__|$${APP_IP}|g" /opt/observeops/monitoring/prometheus/prometheus.yml

# ── Inject AlertManager Config ────────────────────────────────────────────────
# Replace placeholder URLs with real values from SSM and from Terraform variables
SLACK_CRITICAL=$(aws ssm get-parameter \
  --name "/observeops/production/slack_webhook_critical" \
  --with-decryption \
  --region ${aws_region} \
  --query 'Parameter.Value' \
  --output text 2>/dev/null || echo "")

SLACK_WARNINGS=$(aws ssm get-parameter \
  --name "/observeops/production/slack_webhook_warnings" \
  --with-decryption \
  --region ${aws_region} \
  --query 'Parameter.Value' \
  --output text 2>/dev/null || echo "")

LAMBDA_URL=$(aws ssm get-parameter \
  --name "/observeops/production/lambda_incident_url" \
  --region ${aws_region} \
  --query 'Parameter.Value' \
  --output text 2>/dev/null || echo "http://localhost:9999/unused")

sed -i "s|__SLACK_WEBHOOK_CRITICAL__|$${SLACK_CRITICAL:-http://localhost:9999/unused}|g" /opt/observeops/monitoring/alertmanager/alertmanager.yml
sed -i "s|__SLACK_WEBHOOK_WARNINGS__|$${SLACK_WARNINGS:-http://localhost:9999/unused}|g" /opt/observeops/monitoring/alertmanager/alertmanager.yml
sed -i "s|__LAMBDA_FUNCTION_URL__|$${LAMBDA_URL}|g" /opt/observeops/monitoring/alertmanager/alertmanager.yml
# LLM Autopilot webhook: alertmanager runs on obs server, autopilot on app server
sed -i "s|__LLM_AUTOPILOT_WEBHOOK__|http://$${APP_IP}:8080/webhook|g" /opt/observeops/monitoring/alertmanager/alertmanager.yml

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
