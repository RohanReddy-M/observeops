#!/bin/bash
set -e

exec > /var/log/user_data.log 2>&1

echo "Starting observability server setup for ${project_name}"

# Update system
apt-get update -y
apt-get upgrade -y

# Install required packages
apt-get install -y curl git unzip jq htop

# Install Docker
curl -fsSL https://get.docker.com | sh
systemctl enable docker
systemctl start docker
usermod -aG docker ubuntu

# Install Docker Compose plugin
apt-get install -y docker-compose-v2

# Install AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip /tmp/awscliv2.zip -d /tmp
/tmp/aws/install

# Create app directory
mkdir -p /opt/observeops
chown ubuntu:ubuntu /opt/observeops

echo "Observability server ready for ${project_name}"