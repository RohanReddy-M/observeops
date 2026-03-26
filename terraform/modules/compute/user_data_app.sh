#!/bin/bash
set -e
exec > /var/log/user_data.log 2>&1

echo "Starting setup at $(date)"

# Install Docker
curl -fsSL https://get.docker.com | sh
systemctl enable docker
systemctl start docker

# Install dependencies
apt-get install -y git

# Clone repo
git clone https://github.com/RohanReddy-M/observeops.git /opt/observeops

# Fix AlertManager config with real Slack webhook
cat > /opt/observeops/monitoring/alertmanager/alertmanager.yml << 'ALERTEOF'
global:
  resolve_timeout: 5m
  slack_api_url: 'YOUR_SLACK_WEBHOOK_URL'
route:
  receiver: slack-warnings
  group_by: [alertname, job]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  routes:
    - match:
        severity: critical
      receiver: slack-critical
      repeat_interval: 1h
    - match:
        severity: warning
      receiver: slack-warnings
receivers:
  - name: slack-critical
    slack_configs:
      - channel: '#alerts-critical'
        send_resolved: true
        title: 'CRITICAL: {{ .GroupLabels.alertname }}'
        text: |
          *Summary:* {{ range .Alerts }}{{ .Annotations.summary }}{{ end }}
  - name: slack-warnings
    slack_configs:
      - channel: '#alerts-warnings'
        send_resolved: true
        title: 'WARNING: {{ .GroupLabels.alertname }}'
        text: |
          *Summary:* {{ range .Alerts }}{{ .Annotations.summary }}{{ end }}
inhibit_rules:
  - source_match:
      severity: critical
    target_match:
      severity: warning
    equal: [alertname, job]
ALERTEOF

# Add GROQ API key to docker-compose
sed -i 's/- GROQ_API_KEY=YOUR_GROQ_API_KEY_HERE/- GROQ_API_KEY=${groq_api_key}/' /opt/observeops/docker-compose.yml

# Start stack
cd /opt/observeops
docker compose up -d

echo "Setup complete at $(date)"
