# ─── EC2 Instances ────────────────────────────────────────────────────────────
# We create two EC2 instances:
# 1. App Server: runs SecureShip, StatusService, Nginx
# 2. Observability Server: runs Prometheus, Grafana, Loki, AlertManager
#
# Why separate? 
# - If monitoring runs on the same server as the app,
#   when the app has a problem (high CPU/memory), monitoring is also affected
# - You can't trust monitoring that runs on the thing it's monitoring
# - In production, observability infra is always separate

# No SSH key pair. Port 22 is not open in any security group and all access is
# through SSM Session Manager (ADR-002). A key pair used to be created here and
# installed on both instances anyway: unusable, but still a credential on the box
# and a file every operator had to have before `terraform apply` would run.

# ─── IAM Role for EC2 ─────────────────────────────────────────────────────────
# Instead of putting AWS credentials on the EC2 instance (dangerous),
# we attach an IAM Role. The instance can then make AWS API calls
# using temporary credentials that rotate automatically.
# This is the correct production pattern.

# The trust policy: who can assume this role
data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name               = "${var.project_name}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
  tags               = var.common_tags
}

# What permissions the EC2 instance has
resource "aws_iam_role_policy" "ec2" {
  name = "${var.project_name}-ec2-policy"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          # ecr:GetAuthorizationToken doesn't support resource-level permissions —
          # AWS requires Resource "*" for this specific action, it's not a choice.
          Effect   = "Allow"
          Action   = ["ecr:GetAuthorizationToken"]
          Resource = "*"
        },
        {
          # Unlike GetAuthorizationToken above, these three DO support resource
          # scoping — previously left as "*", which meant this role could pull
          # from any ECR repo in the account, not just this project's four.
          Effect = "Allow"
          Action = [
            "ecr:GetDownloadUrlForLayer",
            "ecr:BatchGetImage",
            "ecr:BatchCheckLayerAvailability"
          ]
          Resource = length(var.ecr_repository_arns) > 0 ? var.ecr_repository_arns : ["*"]
        },
        {
          # Scoped to this project's own log group prefix — previously "*" meant
          # this role could write to (and, via DescribeLogStreams, enumerate) any
          # CloudWatch log group in the account, not just its own.
          Effect = "Allow"
          Action = [
            "logs:CreateLogGroup",
            "logs:CreateLogStream",
            "logs:PutLogEvents",
            "logs:DescribeLogStreams"
          ]
          Resource = "arn:aws:logs:${var.aws_region}:*:log-group:/${var.project_name}/*:*"
        },
      ],
      [
        {
          # Allow SSM Session Manager (SSH alternative, more secure)
          Effect = "Allow"
          Action = [
            "ssm:UpdateInstanceInformation",
            "ssmmessages:CreateControlChannel",
            "ssmmessages:CreateDataChannel",
            "ssmmessages:OpenControlChannel",
            "ssmmessages:OpenDataChannel"
          ]
          Resource = "*"
        },
        {
          # Read application secrets from SSM Parameter Store.
          # Scoped to only our project's parameters — least privilege.
          # This is how GROQ_API_KEY gets to the EC2 instance without
          # appearing in git, environment variables, or AMI images.
          Effect   = "Allow"
          Action   = ["ssm:GetParameter", "ssm:GetParameters"]
          Resource = "arn:aws:ssm:*:*:parameter/observeops/*"
        },
        {
          Effect = "Allow"
          Action = [
            "dynamodb:GetItem",
            "dynamodb:PutItem",
            "dynamodb:UpdateItem",
            "dynamodb:DeleteItem",
            "dynamodb:Query",
            "dynamodb:Scan"
          ]
          Resource = "arn:aws:dynamodb:*:*:table/observeops-*"
        }
      ]
    )
  })
}

# Instance profile wraps the role so it can be attached to EC2
resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.ec2.name
}

# ─── App Server ───────────────────────────────────────────────────────────────
resource "aws_instance" "app" {
  # AMI: Amazon Machine Image - the base OS image
  # This is Ubuntu 22.04 LTS for ap-south-1 (Mumbai)
  # LTS = Long Term Support = stable, security patches for 5 years
  ami = var.ubuntu_ami

  # t3.small: 2 vCPU, 2GB RAM - enough for our 2 services + nginx
  # t3 = burstable instances: can burst to 100% CPU occasionally
  # Good for dev/staging, use t3.medium or dedicated for prod
  instance_type = var.app_instance_type

  # Place in private subnet (no public IP, can't be reached directly from internet)
  subnet_id = var.private_subnet_ids[0]

  # Attach security group
  vpc_security_group_ids = [var.app_sg_id]

  # Attach IAM role for ECR access
  iam_instance_profile = aws_iam_instance_profile.ec2.name

  # Root volume: 20GB SSD
  # Docker images + logs can consume significant space
  root_block_device {
    volume_size = 20
    volume_type = "gp3" # gp3 = General Purpose SSD v3, cheaper and faster than gp2
    encrypted   = true  # Encrypt at rest - security best practice

    tags = merge(var.common_tags, {
      Name = "${var.project_name}-app-volume"
    })
  }

  # IMDSv2: Instance Metadata Service v2.
  # Attackers who exploit SSRF bugs can hit the metadata endpoint (169.254.169.254)
  # to steal the IAM role credentials. IMDSv2 requires a session token first,
  # which blocks that attack. This is an AWS security best practice since 2020.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # Forces IMDSv2 (blocks IMDSv1)
    http_put_response_hop_limit = 1          # Prevents containers from reaching IMDS
  }

  user_data = base64encode(templatefile("${path.module}/user_data_app.sh", {
    project_name = var.project_name
    aws_region   = var.aws_region
  }))

  # user_data reads the API key from SSM at first boot. Without this the instance
  # could boot before the parameter exists, start secureship with no key, and have
  # it refuse to start (auth is fail-closed once a DynamoDB table is configured).
  depends_on = [aws_ssm_parameter.secureship_api_key]

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-app-server"
    Role = "application"
  })
}

# ─── Observability Server ─────────────────────────────────────────────────────
resource "aws_instance" "observability" {
  ami           = var.ubuntu_ami
  instance_type = var.obs_instance_type # t3.small is fine for Prometheus+Grafana

  subnet_id              = var.private_subnet_ids[1]
  vpc_security_group_ids = [var.observability_sg_id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  root_block_device {
    volume_size = 30 # Prometheus TSDB and Loki need more space
    volume_type = "gp3"
    encrypted   = true

    tags = merge(var.common_tags, {
      Name = "${var.project_name}-obs-volume"
    })
  }

  user_data = base64encode(templatefile("${path.module}/user_data_obs.sh", {
    project_name    = var.project_name
    app_server_ip   = aws_instance.app.private_ip
    aws_region      = var.aws_region
    public_base_url = var.public_base_url
  }))

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-obs-server"
    Role = "observability"
  })

  depends_on = [aws_instance.app]
}

# ─── SecureShip API key ───────────────────────────────────────────────────────
# Generated here, stored encrypted in SSM, read by user_data at boot and by
# deploy.sh on every deploy. It never appears in git, in a tfvars file or in CI.
# (It is in Terraform state, which is why the S3 backend has encryption enabled.)
#
# Before this existed nothing ever supplied API_KEY, so the API ran with
# authentication switched off in every environment it was deployed to.
resource "random_password" "secureship_api_key" {
  length  = 40
  special = false # sent as an HTTP header and written to a dotenv file; keep it shell-safe
}

resource "aws_ssm_parameter" "secureship_api_key" {
  name        = "/${var.project_name}/production/secureship_api_key"
  description = "X-API-Key for the SecureShip API"
  type        = "SecureString"
  value       = random_password.secureship_api_key.result
  tags        = var.common_tags
}

resource "aws_ssm_parameter" "obs_server_ip" {
  name  = "/${var.project_name}/production/obs_server_ip"
  type  = "String"
  value = aws_instance.observability.private_ip
  tags  = var.common_tags
}
