# ─── Staging Environment ──────────────────────────────────────────────────────
# Deploy: terraform apply -var-file=environments/staging.tfvars \
#                         -backend-config=key=staging/terraform.tfstate
#
# Staging is intentionally smaller than production to reduce cost.
# Use it to validate infrastructure changes before promoting to production.
# Staging is safe to destroy between testing sessions — zero idle cost.

environment = "staging"
aws_region  = "ap-south-1"

# Separate CIDR range avoids overlap if you ever VPC-peer staging ↔ prod
vpc_cidr             = "10.1.0.0/16"
public_subnet_cidrs  = ["10.1.1.0/24", "10.1.2.0/24"]
private_subnet_cidrs = ["10.1.3.0/24", "10.1.4.0/24"]
availability_zones   = ["ap-south-1a", "ap-south-1b"]

# t3.micro = 2 vCPU / 1 GB RAM — fine for staging load tests
# Upgrade to t3.small if Prometheus OOMs under test load
app_instance_type = "t3.micro"
obs_instance_type = "t3.micro"
