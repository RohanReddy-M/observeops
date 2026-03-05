#!/bin/bash
# ─── ObserveOps EC2 Installation Script ──────────────────────────────────────
# Run this ONCE on a fresh Ubuntu EC2 instance.
# It installs everything needed to run the ObserveOps platform.
#
# Usage: 
#   chmod +x install.sh
#   ./install.sh
#
# What this does:
# 1. Updates system packages
# 2. Installs Docker + Docker Compose
# 3. Installs AWS CLI (for ECR image pulls)
# 4. Configures system for production use
# 5. Sets up the application directory

set -e  # Exit immediately if any command fails
# Why set -e: without it, the script continues even if a step fails,
# which can leave your system in a broken half-installed state

echo "═══════════════════════════════════════════"
echo "  ObserveOps Platform - Installation"
echo "═══════════════════════════════════════════"

# ─── System Update ────────────────────────────────────────────────────────────
echo "[1/6] Updating system packages..."
# apt-get update: refreshes the package list from Ubuntu's package repositories
# apt-get upgrade: installs newer versions of all installed packages
# -y flag: automatically answer "yes" to all prompts (needed for scripts)
sudo apt-get update -y
sudo apt-get upgrade -y

# Install useful tools we'll use for debugging
# curl: HTTP requests (testing APIs, downloading files)
# jq: parsing JSON in the terminal (super useful for AWS CLI output)
# htop: better version of top for process monitoring
# tree: shows directory structure
# net-tools: provides netstat for network debugging
# unzip: needed for AWS CLI installation
sudo apt-get install -y curl jq htop tree net-tools unzip git

# ─── Docker Installation ──────────────────────────────────────────────────────
echo "[2/6] Installing Docker..."

# Remove any old Docker versions that might be installed
sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

# Add Docker's official GPG key (verifies packages are authentic)
sudo apt-get install -y ca-certificates gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# Add Docker's repository to apt sources
echo \
  "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker Engine, CLI, and Docker Compose plugin
sudo apt-get update -y
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Add current user to docker group so we don't need sudo for every docker command
# Why: running docker with sudo all the time is annoying and in scripts it causes issues
sudo usermod -aG docker $USER

# Enable Docker to start automatically when EC2 reboots
# Without this, Docker stops after every instance restart
sudo systemctl enable docker
sudo systemctl start docker

echo "Docker version: $(sudo docker --version)"

# ─── AWS CLI Installation ─────────────────────────────────────────────────────
echo "[3/6] Installing AWS CLI..."
# AWS CLI lets us pull Docker images from ECR and interact with AWS services
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip -q awscliv2.zip
sudo ./aws/install
rm -rf awscliv2.zip aws/
echo "AWS CLI version: $(aws --version)"

# ─── System Configuration ─────────────────────────────────────────────────────
echo "[4/6] Configuring system..."

# Increase the number of open file descriptors
# Why: each Docker container, network connection, and log file uses a file descriptor
# Default limit (1024) is too low for running multiple containers
echo "* soft nofile 65536" | sudo tee -a /etc/security/limits.conf
echo "* hard nofile 65536" | sudo tee -a /etc/security/limits.conf

# Configure swap space (2GB)
# Why: if your app uses more RAM than available, swap prevents OOMKill
# It's slower than RAM but better than crashing
if [ ! -f /swapfile ]; then
    sudo fallocate -l 2G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
    echo "Swap created: 2GB"
fi

# ─── Application Directory Setup ─────────────────────────────────────────────
echo "[5/6] Setting up application directory..."

# Create the directory where we'll put our application files
sudo mkdir -p /opt/observeops
sudo chown $USER:$USER /opt/observeops

# Create log directory
sudo mkdir -p /var/log/observeops
sudo chown $USER:$USER /var/log/observeops

# ─── Firewall Configuration ───────────────────────────────────────────────────
echo "[6/6] Configuring firewall..."
# UFW = Uncomplicated Firewall (Linux host-level firewall)
# Note: AWS Security Groups are the main firewall.
# UFW is a second layer of defense (defense in depth principle)

sudo apt-get install -y ufw

# Default: deny all incoming, allow all outgoing
sudo ufw default deny incoming
sudo ufw default allow outgoing

# Allow SSH (port 22) - CRITICAL: if you forget this, you'll be locked out!
sudo ufw allow 22/tcp comment 'SSH'

# Allow our application ports
# In production, only 80/443 should be internet-facing
# 8001, 8002 should only be accessible internally (via Security Groups)
sudo ufw allow 80/tcp comment 'HTTP'
sudo ufw allow 443/tcp comment 'HTTPS'

# Enable firewall (--force prevents interactive prompt in scripts)
sudo ufw --force enable

echo ""
echo "═══════════════════════════════════════════"
echo "  Installation Complete!"
echo "═══════════════════════════════════════════"
echo ""
echo "IMPORTANT: Log out and back in for docker group to take effect"
echo "Then run: ./deploy.sh to start the platform"
echo ""
echo "System info:"
echo "  Docker: $(sudo docker --version)"
echo "  AWS CLI: $(aws --version)"
echo "  Swap: $(free -h | grep Swap)"
echo "  Disk: $(df -h / | tail -1)"
