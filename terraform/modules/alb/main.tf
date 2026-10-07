# ─── Application Load Balancer ────────────────────────────────────────────────
# EC2 instances live in private subnets — no public IPs, no direct access.
#
# Two modes, chosen by var.domain_name:
#
#   domain_name = "example.com"   User → Route 53 → ALB (HTTPS, ACM cert) → nginx
#                                 Port 80 redirects to 443.
#
#   domain_name = ""  (default)   User → ALB's own AWS DNS name (HTTP) → nginx
#                                 No hosted zone, no certificate, no listener on 443.
#
# The domain used to be hardcoded. When its registration lapsed, certificate
# validation could never complete and `terraform apply` hung until it timed out:
# an expired registration was enough to make the whole stack unbuildable. A domain
# is now something you add to a working stack, not something the stack needs.

locals {
  has_domain = var.domain_name != ""
}

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
  count = local.has_domain ? 1 : 0

  name = var.domain_name
  tags = var.common_tags
}

# ─── ACM Certificate ──────────────────────────────────────────────────────────
# Request a free TLS cert for the domain. AWS validates ownership via DNS.
resource "aws_acm_certificate" "main" {
  count = local.has_domain ? 1 : 0

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
  # The splat yields an empty list when no certificate exists, so with no domain
  # this map is empty and no validation records are planned.
  for_each = {
    for dvo in flatten(aws_acm_certificate.main[*].domain_validation_options) : dvo.domain_name => {
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
  zone_id         = aws_route53_zone.main[0].zone_id
}

# Terraform waits here until AWS confirms the cert is issued (~2-5 min)
resource "aws_acm_certificate_validation" "main" {
  count = local.has_domain ? 1 : 0

  certificate_arn         = aws_acm_certificate.main[0].arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

# ─── HTTPS Listener (port 443) ────────────────────────────────────────────────
resource "aws_lb_listener" "https" {
  count = local.has_domain ? 1 : 0

  load_balancer_arn = aws_lb.main.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.main[0].certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  tags = var.common_tags
}

# ─── HTTP Listener (port 80) ──────────────────────────────────────────────────
# With a domain: redirect everything to HTTPS.
# Without one: there is no certificate to terminate TLS with, so serve HTTP.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = local.has_domain ? "redirect" : "forward"
    target_group_arn = local.has_domain ? null : aws_lb_target_group.app.arn

    dynamic "redirect" {
      for_each = local.has_domain ? [1] : []
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }

  tags = var.common_tags
}

# ─── Route 53 A Record ────────────────────────────────────────────────────────
resource "aws_route53_record" "app" {
  count = local.has_domain ? 1 : 0

  zone_id = aws_route53_zone.main[0].zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}
