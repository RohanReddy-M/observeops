# ─── EC2 Instances ────────────────────────────────────────────────────────────
# Two instances, one job each (ADR-001):
#   app server            nginx, SecureShip, StatusService, RAGService, alert autopilot
#   observability server  Prometheus, AlertManager, Grafana, Loki, Tempo
#
# They are separate so that the thing being watched cannot take down the thing
# watching it: an application that eats all the memory on its host would
# otherwise silence the monitoring that should report it.
#
# No SSH key pair exists. Port 22 is not open in any security group and all
# access is through SSM Session Manager (ADR-002).

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id

  # Every parameter this project owns lives under one path, so one ARN pattern
  # covers "this project's configuration and secrets" and nothing else in the
  # account. Region and account are spelled out rather than left as "*".
  ssm_parameters_arn = "arn:aws:ssm:${var.aws_region}:${local.account_id}:parameter/${var.project_name}/*"

  ec2_assume_role = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  # What the SSM agent needs so that Session Manager and Run Command work.
  # This is how deploys reach the instance (CI sends a command) and how a human
  # gets a shell, with no inbound port.
  ssm_agent_statement = {
    Effect = "Allow"
    Action = [
      "ssm:UpdateInstanceInformation",
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
      "ec2messages:AcknowledgeMessage",
      "ec2messages:DeleteMessage",
      "ec2messages:FailMessage",
      "ec2messages:GetEndpoint",
      "ec2messages:GetMessages",
      "ec2messages:SendReply"
    ]
    Resource = "*"
  }

  read_project_parameters_statement = {
    Effect   = "Allow"
    Action   = ["ssm:GetParameter", "ssm:GetParameters"]
    Resource = local.ssm_parameters_arn
  }
}

# ─── IAM: one role per server ─────────────────────────────────────────────────
# An instance role is how software on the instance gets AWS credentials without
# any key being stored on it: the credentials are temporary and rotate on their
# own. Each server gets its own role holding only what that server does.
#
# Both servers used to share one role. The observability server could therefore
# pull the application images and read and write the application's database
# table, neither of which it has any reason to do. The shared policy also named
# DynamoDB tables as "observeops-*", which matched the Terraform state lock
# table as well as the application's.

resource "aws_iam_role" "app" {
  name               = "${var.project_name}-app-role"
  assume_role_policy = local.ec2_assume_role
  tags               = var.common_tags
}

resource "aws_iam_role_policy" "app" {
  name = "${var.project_name}-app-policy"
  role = aws_iam_role.app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      local.ssm_agent_statement,
      local.read_project_parameters_statement,
      {
        # GetAuthorizationToken does not support resource-level permissions:
        # AWS requires "*" for it. It only returns a login token; what can be
        # pulled with that token is decided by the next statement.
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        # Pull only. Only this project's repositories.
        Effect = "Allow"
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability"
        ]
        Resource = var.ecr_repository_arns
      },
      {
        # The one table SecureShip stores ships in, by exact ARN.
        # DescribeTable is what the /ready endpoint calls to prove it can reach
        # the table; without it readiness fails and the deploy rolls back.
        Effect = "Allow"
        Action = [
          "dynamodb:DescribeTable",
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem",
          "dynamodb:Query",
          "dynamodb:Scan"
        ]
        Resource = var.dynamodb_table_arn
      }
    ]
  })
}

resource "aws_iam_instance_profile" "app" {
  name = "${var.project_name}-app-profile"
  role = aws_iam_role.app.name
}

resource "aws_iam_role" "obs" {
  name               = "${var.project_name}-obs-role"
  assume_role_policy = local.ec2_assume_role
  tags               = var.common_tags
}

# The observability server runs public images only and talks to no AWS data
# service. It needs the SSM agent and its own secrets (Slack webhooks, the
# Grafana password), and that is all it gets.
resource "aws_iam_role_policy" "obs" {
  name = "${var.project_name}-obs-policy"
  role = aws_iam_role.obs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      local.ssm_agent_statement,
      local.read_project_parameters_statement,
    ]
  })
}

resource "aws_iam_instance_profile" "obs" {
  name = "${var.project_name}-obs-profile"
  role = aws_iam_role.obs.name
}

# ─── App Server ───────────────────────────────────────────────────────────────
resource "aws_instance" "app" {
  ami           = var.ubuntu_ami
  instance_type = var.app_instance_type # t3.small: 2 vCPU, 2 GB. Burstable, which suits a demo load

  # Private subnet: no public IP. The only way in from the internet is the ALB.
  subnet_id              = var.private_subnet_ids[0]
  vpc_security_group_ids = [var.app_sg_id]
  iam_instance_profile   = aws_iam_instance_profile.app.name

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true

    tags = merge(var.common_tags, { Name = "${var.project_name}-app-volume" })
  }

  # The instance metadata service (169.254.169.254) is where software on the
  # instance collects the role's temporary credentials.
  #
  # http_tokens = "required" is IMDSv2: a caller must first PUT for a session
  # token and present it on every read. A server-side request forgery bug can
  # usually make the application issue a GET to an attacker's URL, but not a PUT
  # with a custom header, which is what made IMDSv1 credential theft so easy.
  #
  # The hop limit is how many network hops that token response may travel. A
  # container on Docker's bridge network is one hop further away than the host,
  # so with a limit of 1 containers cannot get credentials at all. That is the
  # safest setting and it is what this had, with one consequence nobody noticed:
  # SecureShip runs in a container and reads DynamoDB with the instance role, so
  # in production it could never authenticate and every data request failed,
  # while /health, which touched nothing, stayed green. It is 2 here because a
  # container on this host genuinely needs the role. The cost is that EVERY
  # container on this host can now obtain it, which is why the role above is
  # scoped to one table, four repositories and one parameter path.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  user_data = templatefile("${path.module}/user_data_app.sh", {
    project_name = var.project_name
    aws_region   = var.aws_region
  })

  # user_data reads the API key from SSM at first boot. Without this the instance
  # could boot before the parameter exists, start secureship with no key, and have
  # it refuse to start (auth is fail-closed once a DynamoDB table is configured).
  depends_on = [aws_ssm_parameter.secureship_api_key, aws_iam_role_policy.app]

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-app-server"
    Role = "application"
  })
}

# ─── Observability Server ─────────────────────────────────────────────────────
resource "aws_instance" "observability" {
  ami           = var.ubuntu_ami
  instance_type = var.obs_instance_type

  subnet_id              = var.private_subnet_ids[1]
  vpc_security_group_ids = [var.observability_sg_id]
  iam_instance_profile   = aws_iam_instance_profile.obs.name

  root_block_device {
    volume_size = 30 # Prometheus, Loki and Tempo all store data here
    volume_type = "gp3"
    encrypted   = true

    tags = merge(var.common_tags, { Name = "${var.project_name}-obs-volume" })
  }

  # IMDSv2 here too. This block was missing, so this instance accepted IMDSv1
  # while the documentation said IMDSv2 was enforced on every instance.
  # No container on this host needs AWS credentials, so the hop limit stays at 1
  # and none of them can reach the metadata service.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  user_data = templatefile("${path.module}/user_data_obs.sh", {
    project_name    = var.project_name
    app_server_ip   = aws_instance.app.private_ip
    aws_region      = var.aws_region
    public_base_url = var.public_base_url
  })

  depends_on = [aws_ssm_parameter.grafana_admin_password, aws_iam_role_policy.obs]

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-obs-server"
    Role = "observability"
  })
}

# ─── Generated secrets ────────────────────────────────────────────────────────
# Generated here, stored encrypted in SSM, read by user_data at boot and by
# deploy.sh on every deploy. They never appear in git, in a tfvars file or in CI.
# (They are in Terraform state, which is why the S3 backend is encrypted and the
# bucket is private.)

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

# Grafana is reachable from the internet through the load balancer at /grafana/.
# Its admin password used to be a fixed string written in docker-compose.yml, in
# the README and in a public repository.
resource "random_password" "grafana_admin" {
  length  = 24
  special = false
}

resource "aws_ssm_parameter" "grafana_admin_password" {
  name        = "/${var.project_name}/production/grafana_admin_password"
  description = "Grafana admin password (user: admin)"
  type        = "SecureString"
  value       = random_password.grafana_admin.result
  tags        = var.common_tags
}

resource "aws_ssm_parameter" "obs_server_ip" {
  name  = "/${var.project_name}/production/obs_server_ip"
  type  = "String"
  value = aws_instance.observability.private_ip
  tags  = var.common_tags
}
