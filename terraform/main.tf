# ─── ObserveOps - Terraform Root Configuration ───────────────────────────────
# This is the entry point for all infrastructure.
# It calls our modules and wires them together.
#
# Workflow:
#   terraform init     - download providers and modules
#   terraform plan     - show what will be created/changed/destroyed
#   terraform apply    - actually create/change infrastructure
#   terraform destroy  - tear everything down (stops billing)
#
# ALWAYS run terraform plan before terraform apply.
# Read every line of the plan before typing "yes".

terraform {
  required_version = ">= 1.5.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # ─── Remote State ───────────────────────────────────────────────────────────
  # Terraform stores state (current infrastructure snapshot) in S3.
  # WHY: If you store state locally and your laptop dies, you lose track
  # of what Terraform created and can't manage it anymore.
  # S3 + DynamoDB = safe, team-shareable state storage.
  #
  # SETUP REQUIRED: Create these before running terraform init:
  #   aws s3 mb s3://observeops-terraform-state-YOUR_ACCOUNT_ID
  #   aws dynamodb create-table \
  #     --table-name observeops-terraform-locks \
  #     --attribute-definitions AttributeName=LockID,AttributeType=S \
  #     --key-schema AttributeName=LockID,KeyType=HASH \
  #     --billing-mode PAY_PER_REQUEST
  backend "s3" {
    bucket         = "observeops-terraform-state"    # Change to your bucket name
    key            = "production/terraform.tfstate"
    region         = "ap-south-1"
    encrypt        = true
    dynamodb_table = "observeops-terraform-locks"
  }
}

# ─── AWS Provider ─────────────────────────────────────────────────────────────
provider "aws" {
  region = var.aws_region

  # Default tags applied to EVERY resource
  # This enables cost tracking in AWS Cost Explorer by project
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Owner       = "devops"
      CostCenter  = "observeops"
    }
  }
}

# ─── Data Sources ─────────────────────────────────────────────────────────────
# Data sources READ existing AWS resources (they don't create anything)

# Get the latest Ubuntu 22.04 LTS AMI ID for our region
# AMI IDs are region-specific, so we look it up dynamically instead of hardcoding
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]    # Canonical (Ubuntu's publisher) account ID

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ─── VPC Module ───────────────────────────────────────────────────────────────
module "vpc" {
  source = "./modules/vpc"

  project_name         = var.project_name
  vpc_cidr             = var.vpc_cidr
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  availability_zones   = var.availability_zones
  common_tags          = local.common_tags
}

# ─── Security Groups Module ───────────────────────────────────────────────────
module "security" {
  source = "./modules/security"

  project_name = var.project_name
  vpc_id       = module.vpc.vpc_id
  vpc_cidr     = module.vpc.vpc_cidr
  admin_cidr   = var.admin_cidr
  common_tags  = local.common_tags
}

# ─── Compute Module ───────────────────────────────────────────────────────────
module "compute" {
  source = "./modules/compute"

  project_name        = var.project_name
  aws_region          = var.aws_region
  ubuntu_ami          = data.aws_ami.ubuntu.id
  private_subnet_ids  = module.vpc.private_subnet_ids
  app_sg_id           = module.security.app_sg_id
  observability_sg_id = module.security.observability_sg_id
  public_key_path     = var.public_key_path
  common_tags         = local.common_tags
}

# ─── Locals ───────────────────────────────────────────────────────────────────
# Locals = computed values that you reference in multiple places
locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ─── ECR Repositories ─────────────────────────────────────────────────────────
# ECR = Elastic Container Registry = AWS's private Docker registry
# We push our built images here, EC2 instances pull from here

resource "aws_ecr_repository" "secureship" {
  name                 = "${var.project_name}/secureship"
  image_tag_mutability = "MUTABLE"

  # Scan images for known vulnerabilities automatically on push
  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.common_tags
}

resource "aws_ecr_repository" "statusservice" {
  name                 = "${var.project_name}/statusservice"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.common_tags
}

# Auto-delete old images to control storage costs
# Keep only the last 10 images per repository
resource "aws_ecr_lifecycle_policy" "secureship" {
  repository = aws_ecr_repository.secureship.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}
