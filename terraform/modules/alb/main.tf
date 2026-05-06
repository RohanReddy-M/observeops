# ─── Application Load Balancer ────────────────────────────────────────────────
# Traffic flow: User → secureship.click → Route53 → ALB (HTTPS) → EC2 (HTTP)
# EC2 instances live in private subnets — no public IPs, no direct access.

resource "aws_lb" "main" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_sg_id]
  subnets            = var.public_subnet_ids

  enable_deletion_protection = false

  tags = var.common_tags
}

# ─── Target Group ─────────────────────────────────────────────────────────────
resource "aws_lb_target_group" "app" {
  name     = "${var.project_name}-app-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    enabled             = true
    path                = "/nginx-health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
    matcher             = "200"
  }

  tags = var.common_tags
}

resource "aws_lb_target_group_attachment" "app" {
  target_group_arn = aws_lb_target_group.app.arn
  target_id        = var.app_instance_id
  port             = 80
}

# ─── Route 53 Hosted Zone ─────────────────────────────────────────────────────
# Managed by Terraform so it can be destroyed (zero cost) and recreated on demand.
resource "aws_route53_zone" "main" {
  name = var.domain_name
  tags = var.common_tags
}

# ─── ACM Certificate ──────────────────────────────────────────────────────────
# Request a free TLS cert for the domain. AWS validates ownership via DNS.
resource "aws_acm_certificate" "main" {
  domain_name       = var.domain_name
  validation_method = "DNS"

  # Must create before destroying old cert during updates
  lifecycle {
    create_before_destroy = true
  }

  tags = var.common_tags
}

# Route53 records that prove we own the domain (AWS checks these)
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.main.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = aws_route53_zone.main.zone_id
}

# Terraform waits here until AWS confirms the cert is issued (~2-5 min)
resource "aws_acm_certificate_validation" "main" {
  certificate_arn         = aws_acm_certificate.main.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

# ─── HTTPS Listener (port 443) ────────────────────────────────────────────────
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.main.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  tags = var.common_tags
}

# ─── HTTP → HTTPS Redirect ────────────────────────────────────────────────────
# Anyone hitting port 80 gets redirected to HTTPS automatically
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

  tags = var.common_tags
}

# ─── Route 53 A Record ────────────────────────────────────────────────────────
resource "aws_route53_record" "app" {
  zone_id = aws_route53_zone.main.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}
