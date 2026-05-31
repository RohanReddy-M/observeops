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

# ── Directory Structure ───────────────────────────────────────────────────────
mkdir -p /opt/observeops
mkdir -p /var/log/observeops
chown -R ubuntu:ubuntu /opt/observeops /var/log/observeops

# ── Pull Configuration ────────────────────────────────────────────────────────
cd /opt/observeops
git clone https://github.com/RohanReddy-M/observeops.git .
chown -R ubuntu:ubuntu /opt/observeops

# ── Point Prometheus at the App Server ───────────────────────────────────────
# In docker-compose, services find each other by container name.
# On EC2, the app services are on a DIFFERENT machine, so we replace
# container names with the actual private IP of the app server.
APP_IP="${app_server_ip}"

sed -i "s/secureship:8001/$${APP_IP}:8001/g"   /opt/observeops/monitoring/prometheus/prometheus.yml
sed -i "s/statusservice:8002/$${APP_IP}:8002/g" /opt/observeops/monitoring/prometheus/prometheus.yml
sed -i "s/ragservice:8003/$${APP_IP}:8003/g"    /opt/observeops/monitoring/prometheus/prometheus.yml

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

[ -n "$SLACK_CRITICAL" ] && sed -i "s|__SLACK_WEBHOOK_CRITICAL__|$${SLACK_CRITICAL}|g" /opt/observeops/monitoring/alertmanager/alertmanager.yml
[ -n "$SLACK_WARNINGS" ] && sed -i "s|__SLACK_WEBHOOK_WARNINGS__|$${SLACK_WARNINGS}|g" /opt/observeops/monitoring/alertmanager/alertmanager.yml
sed -i "s|__LAMBDA_FUNCTION_URL__|$${LAMBDA_URL}|g"   /opt/observeops/monitoring/alertmanager/alertmanager.yml
sed -i "s|__SLACK_WEBHOOK_CRITICAL__|http://localhost:9999/unused|g" /opt/observeops/monitoring/alertmanager/alertmanager.yml
sed -i "s|__SLACK_WEBHOOK_WARNINGS__|http://localhost:9999/unused|g" /opt/observeops/monitoring/alertmanager/alertmanager.yml

# LLM Autopilot runs on the app server — replace container name with real IP
sed -i "s|http://llm-alert-autopilot:8080|http://$${APP_IP}:8080|g" /opt/observeops/monitoring/alertmanager/alertmanager.yml

# ── Start Monitoring Services ─────────────────────────────────────────────────
cd /opt/observeops
sudo -u ubuntu docker compose up -d prometheus grafana loki promtail alertmanager node-exporter

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
ExecStart=/usr/bin/docker compose up -d prometheus grafana loki promtail alertmanager node-exporter
ExecStop=/usr/bin/docker compose stop prometheus grafana loki promtail alertmanager node-exporter
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
