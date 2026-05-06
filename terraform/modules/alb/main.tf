# ─── Application Load Balancer ────────────────────────────────────────────────
# The ALB is the only thing that faces the internet.
# EC2 instances live in private subnets — no public IPs, no direct access.
# Traffic flow: User → secureship.click → Route53 → ALB → EC2 (private)
#
# Why ALB over NLB (Network Load Balancer)?
# ALB works at Layer 7 (HTTP). It can:
# - Route based on URL path (/api/* vs /status/*)
# - Terminate SSL (HTTPS)
# - Return health-based responses
# NLB works at Layer 4 (TCP) - faster but dumb, just passes bytes through.
# We use ALB because path-based routing and SSL termination matter to us.

resource "aws_lb" "main" {
  name               = "${var.project_name}-alb"
  internal           = false             # internet-facing (has public IP)
  load_balancer_type = "application"     # Layer 7, not Layer 4
  security_groups    = [var.alb_sg_id]
  subnets            = var.public_subnet_ids  # ALB MUST be in public subnets

  # Deletion protection: prevents accidental terraform destroy in production.
  # Set false here so we can destroy for cost management during development.
  enable_deletion_protection = false

  tags = var.common_tags
}

# ─── Target Group ─────────────────────────────────────────────────────────────
# A target group is a named set of instances/IPs that the ALB can route to.
# The ALB health-checks each target. Only healthy targets receive traffic.
resource "aws_lb_target_group" "app" {
  name     = "${var.project_name}-app-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    enabled             = true
    path                = "/nginx-health"    # Our dedicated ALB health endpoint
    healthy_threshold   = 2                  # 2 passes = healthy
    unhealthy_threshold = 3                  # 3 failures = unhealthy (removed from rotation)
    interval            = 30                 # Check every 30 seconds
    timeout             = 5                  # Fail if no response in 5s
    matcher             = "200"
  }

  tags = var.common_tags
}

# Register the app EC2 instance as a target in the group
resource "aws_lb_target_group_attachment" "app" {
  target_group_arn = aws_lb_target_group.app.arn
  target_id        = var.app_instance_id
  port             = 80
}

# ─── HTTP Listener ────────────────────────────────────────────────────────────
# Listens on port 80, forwards all traffic to target group.
# In a production setup with a TLS cert you'd add an HTTPS listener (443)
# and redirect HTTP → HTTPS here.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  tags = var.common_tags
}

# ─── Route 53 DNS Record ──────────────────────────────────────────────────────
# Look up the hosted zone for our domain (secureship.click).
# This zone was created when the domain was registered in Route 53.
data "aws_route53_zone" "main" {
  name         = var.domain_name
  private_zone = false
}

# Create an A record: secureship.click → ALB
# "Alias" is an AWS-specific DNS extension.
# Unlike CNAME: an alias works for root domains (@), has no extra DNS lookup,
# and is free (CNAME queries cost money on Route 53).
resource "aws_route53_record" "app" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true    # Remove from DNS if ALB is unhealthy
  }
}
