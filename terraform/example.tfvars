# Copy this to terraform.tfvars and fill in your values
# NEVER commit terraform.tfvars (it contains your IP address)

project_name = "observeops"
aws_region   = "ap-south-1"
environment  = "production"

# Get your IP: curl ifconfig.me
# Add /32 for single IP: "1.2.3.4/32"
admin_cidr = "YOUR_IP/32"

vpc_cidr             = "10.0.0.0/16"
public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24"]
private_subnet_cidrs = ["10.0.3.0/24", "10.0.4.0/24"]
availability_zones   = ["ap-south-1a", "ap-south-1b"]
