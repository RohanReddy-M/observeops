#!/bin/bash
set -e

# Update system
apt-get update -y
apt-get install -y curl git docker.io docker-compose-v2 awscli

# Start Docker
systemctl enable docker
systemctl start docker

# Add ubuntu user to docker group
usermod -aG docker ubuntu

# Create observability directory
mkdir -p /opt/observeops
chown ubuntu:ubuntu /opt/observeops

echo "Observability server ${project_name} ready" >> /var/log/user_data.log