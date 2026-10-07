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
  # 1.11 is the first release where S3 state locking (use_lockfile) is stable.
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  # ─── Remote State ───────────────────────────────────────────────────────────
  # State is the record of what Terraform created. Kept on a laptop it is lost
  # with the laptop, and two people (or a person and CI) applying at once can
  # corrupt it. So: stored in S3, encrypted, with a lock.
  #
  # use_lockfile makes S3 itself hold the lock, as a small ".tflock" object next
  # to the state, written with a conditional put so only one writer can win.
  # This replaced a DynamoDB lock table: `dynamodb_table` is deprecated in the S3
  # backend, and the table was one more thing to create by hand before the first
  # `terraform init`.
  #
  # The key is supplied at init so each environment has its own state file:
  #   terraform init -backend-config=key=production/terraform.tfstate
  # scripts/bootstrap-aws-account.sh creates the bucket.
  backend "s3" {
    bucket       = "observeops-terraform-state-198239799708"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true
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
  owners      = ["099720109477"] # Canonical (Ubuntu's publisher) account ID

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
  enable_https = var.domain_name != ""
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
  app_instance_type   = var.app_instance_type
  obs_instance_type   = var.obs_instance_type
  common_tags         = local.common_tags
  public_base_url     = module.alb.public_url

  dynamodb_table_arn = module.dynamodb.table_arn

  # The app server's role may pull from these four repositories and no others.
  ecr_repository_arns = [
    aws_ecr_repository.secureship.arn,
    aws_ecr_repository.statusservice.arn,
    aws_ecr_repository.ragservice.arn,
    aws_ecr_repository.llm_alert_autopilot.arn,
  ]

  # Deployment order: DynamoDB and Lambda must be provisioned first so their
  # SSM parameters exist when EC2 user_data runs on first boot.
  # Without this, user_data reads empty SSM params and falls back to defaults.
  depends_on = [module.dynamodb, module.lambda]
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
# Private Docker registry: CI pushes the four service images here, the app
# server pulls them.
#
# Tags are MUTABLE because the pipeline moves two tags on every build (`main`
# and `latest`, used as the build cache source) besides the commit-SHA tag that
# is actually deployed. So "one SHA tag = one image" is a convention the
# pipeline follows, not something the registry enforces. See ADR-008.
#
# force_delete: `terraform destroy` removes the repositories with their images.
# Right for a stack that is torn down between demonstrations, and the reason
# every bring-up starts with a full image build.
resource "aws_ecr_repository" "ragservice" {
  name                 = "${var.project_name}/ragservice"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
  image_scanning_configuration { scan_on_push = true }
  tags = local.common_tags
}

resource "aws_ecr_repository" "secureship" {
  name                 = "${var.project_name}/secureship"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.common_tags
}

resource "aws_ecr_repository" "statusservice" {
  name                 = "${var.project_name}/statusservice"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.common_tags
}

resource "aws_ecr_repository" "llm_alert_autopilot" {
  name                 = "${var.project_name}/llm-alert-autopilot"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.common_tags
}

# ─── ALB + Route53 Module ────────────────────────────────────────────────────
module "alb" {
  source = "./modules/alb"

  project_name      = var.project_name
  vpc_id            = module.vpc.vpc_id
  public_subnet_ids = module.vpc.public_subnet_ids
  alb_sg_id         = module.security.alb_sg_id
  app_instance_id   = module.compute.app_instance_id
  domain_name       = var.domain_name
  common_tags       = local.common_tags
}

# ─── Lambda Module ───────────────────────────────────────────────────────────
module "lambda" {
  source       = "./modules/lambda"
  project_name = var.project_name
  # Only aws_lb.main feeds this output, so the Lambda waits for the load balancer to
  # exist and nothing more. compute depends on this module and the ALB's target
  # attachment depends on compute, but the graph stays acyclic because the load
  # balancer itself depends on neither.
  public_base_url = module.alb.public_url
  common_tags     = local.common_tags
}

# ─── DynamoDB Module ──────────────────────────────────────────────────────────
module "dynamodb" {
  source       = "./modules/dynamodb"
  project_name = var.project_name
  common_tags  = local.common_tags
}

# ─── AWS Budget Alert ─────────────────────────────────────────────────────────
# Emails when the month's spend passes 80% of $10, or is forecast to pass $10.
# The stack costs about $0.15 an hour while it is up (two t3.small, a NAT
# gateway, a load balancer, three public IPv4 addresses), so roughly three days
# of uptime reaches the limit. The point is to hear about a stack that was left
# running before the bill says so.
resource "aws_budgets_budget" "monthly" {
  name         = "${var.project_name}-monthly-budget"
  budget_type  = "COST"
  limit_amount = "10"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Warn at 80% of budget
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  # Alert when forecast exceeds budget (catch runaway spend early)
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}

# ─── ECR Lifecycle Policy ────────────────────────────────────────────────────
# Keep the ten most recent images per repository and expire the rest, so storage
# does not grow with every commit. Ten is also how far back a rollback can reach.
locals {
  ecr_lifecycle_policy = jsonencode({
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

resource "aws_ecr_lifecycle_policy" "secureship" {
  repository = aws_ecr_repository.secureship.name
  policy     = local.ecr_lifecycle_policy
}

resource "aws_ecr_lifecycle_policy" "statusservice" {
  repository = aws_ecr_repository.statusservice.name
  policy     = local.ecr_lifecycle_policy
}

resource "aws_ecr_lifecycle_policy" "ragservice" {
  repository = aws_ecr_repository.ragservice.name
  policy     = local.ecr_lifecycle_policy
}

resource "aws_ecr_lifecycle_policy" "llm_alert_autopilot" {
  repository = aws_ecr_repository.llm_alert_autopilot.name
  policy     = local.ecr_lifecycle_policy
}
