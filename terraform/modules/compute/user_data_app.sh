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

# Create app directory
mkdir -p /opt/observeops
chown ubuntu:ubuntu /opt/observeops

echo "App server ${project_name} ready in ${aws_region}" >> /var/log/user_data.log