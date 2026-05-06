# ─── Security Groups ──────────────────────────────────────────────────────────
# Security Groups = virtual firewall at the instance level.
# They are STATEFUL: if you allow inbound port 80, the response is automatically
# allowed outbound (you don't need an explicit outbound rule for responses).
#
# The security model here:
# Internet → ALB (port 80/443) → EC2 (port 8001/8002 from ALB only)
# Your IP → EC2 (port 22 for SSH)
# EC2 → Internet (all outbound allowed, for package downloads etc.)

# ─── ALB Security Group ───────────────────────────────────────────────────────
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "Security group for Application Load Balancer"
  vpc_id      = var.vpc_id

  # Allow HTTP from anywhere on the internet
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP from internet"
  }

  # Allow HTTPS from anywhere on the internet
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS from internet"
  }

  # Allow all outbound traffic (ALB needs to forward requests to EC2)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"    # -1 means all protocols
    cidr_blocks = ["0.0.0.0/0"]
    description = "All outbound traffic"
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-alb-sg"
  })
}

# ─── Application Server Security Group ───────────────────────────────────────
resource "aws_security_group" "app" {
  name        = "${var.project_name}-app-sg"
  description = "Security group for application EC2 instances"
  vpc_id      = var.vpc_id

  # SSH - ONLY from your IP address
  # Replace with your actual IP: curl ifconfig.me
  # Never use 0.0.0.0/0 for SSH in production - that's how servers get compromised
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
    description = "SSH from admin IP only"
  }

  # SecureShip port - ONLY from ALB security group
  # This is the key security pattern: the app server only accepts traffic from the ALB,
  # not directly from the internet
  ingress {
    from_port       = 8001
    to_port         = 8001
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
    description     = "SecureShip from ALB only"
  }

  # StatusService port - ONLY from ALB
  ingress {
    from_port       = 8002
    to_port         = 8002
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
    description     = "StatusService from ALB only"
  }

  # Allow all traffic within the VPC (for internal service communication)
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
    description = "All traffic within VPC"
  }

  # All outbound: EC2 needs to reach internet for package downloads, ECR pulls, etc.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All outbound traffic"
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-app-sg"
  })
}

# ─── Observability Server Security Group ─────────────────────────────────────
resource "aws_security_group" "observability" {
  name        = "${var.project_name}-obs-sg"
  description = "Security group for observability EC2 instance (Prometheus/Grafana)"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
    description = "SSH from admin"
  }

  # Grafana - accessible from your IP and from within VPC
  ingress {
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr, var.vpc_cidr]
    description = "Grafana from admin and VPC"
  }

  # Prometheus - internal only (shouldn't be public)
  ingress {
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "Prometheus from VPC only"
  }

  # Loki - internal only
  ingress {
    from_port   = 3100
    to_port     = 3100
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "Loki from VPC only"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-obs-sg"
  })
}
