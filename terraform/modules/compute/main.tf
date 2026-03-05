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

# ─── SSH Key Pair ─────────────────────────────────────────────────────────────
# Key pairs are used for SSH authentication.
# AWS stores the PUBLIC key. You keep the PRIVATE key (.pem file).
# Never share your .pem file. Never put it in git.
resource "aws_key_pair" "main" {
  key_name   = "${var.project_name}-key"
  public_key = file(var.public_key_path)

  tags = var.common_tags
}

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
    Statement = [
      {
        # Allow pulling images from ECR (our private Docker registry)
        Effect = "Allow"
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability"
        ]
        Resource = "*"
      },
      {
        # Allow writing logs to CloudWatch
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = "*"
      },
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
      }
    ]
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
  ami           = var.ubuntu_ami
  
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
  
  # SSH key pair
  key_name = aws_key_pair.main.key_name

  # Root volume: 20GB SSD
  # Docker images + logs can consume significant space
  root_block_device {
    volume_size = 20
    volume_type = "gp3"    # gp3 = General Purpose SSD v3, cheaper and faster than gp2
    encrypted   = true     # Encrypt at rest - security best practice
    
    tags = merge(var.common_tags, {
      Name = "${var.project_name}-app-volume"
    })
  }

  # User data: script that runs ONCE when instance first starts
  # This bootstraps our application automatically
  user_data = base64encode(templatefile("${path.module}/user_data_app.sh", {
    project_name = var.project_name
    aws_region   = var.aws_region
  }))

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-app-server"
    Role = "application"
  })
}

# ─── Observability Server ─────────────────────────────────────────────────────
resource "aws_instance" "observability" {
  ami           = var.ubuntu_ami
  instance_type = var.obs_instance_type    # t3.small is fine for Prometheus+Grafana
  
  subnet_id              = var.private_subnet_ids[1]
  vpc_security_group_ids = [var.observability_sg_id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  key_name               = aws_key_pair.main.key_name

  root_block_device {
    volume_size = 30      # Prometheus TSDB and Loki need more space
    volume_type = "gp3"
    encrypted   = true
    
    tags = merge(var.common_tags, {
      Name = "${var.project_name}-obs-volume"
    })
  }

  user_data = base64encode(templatefile("${path.module}/user_data_obs.sh", {
    project_name = var.project_name
    app_server_ip = aws_instance.app.private_ip
  }))

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-obs-server"
    Role = "observability"
  })

  depends_on = [aws_instance.app]
}
