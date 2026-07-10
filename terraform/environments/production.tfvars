# ─── Production Environment ───────────────────────────────────────────────────
# Deploy: terraform apply -var-file=environments/production.tfvars \
#                         -backend-config=key=production/terraform.tfstate
#
# State is isolated per environment — a staging destroy cannot touch prod state.

environment = "production"
aws_region  = "ap-south-1"

# Networking
vpc_cidr             = "10.0.0.0/16"
public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24"]
private_subnet_cidrs = ["10.0.3.0/24", "10.0.4.0/24"]
availability_zones   = ["ap-south-1a", "ap-south-1b"]

# Compute — t3.small gives 2 vCPU / 2 GB RAM, enough for all services + Prometheus
app_instance_type = "t3.small"
obs_instance_type = "t3.small"
