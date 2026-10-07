# ─── Security Groups ──────────────────────────────────────────────────────────
# A security group is a stateful firewall attached to a network interface:
# allow a request in and the reply is allowed out automatically.
#
# Who may talk to whom, and nothing else:
#
#   internet ──80/443──▶ ALB ──80──▶ app server (nginx)
#   obs server ──8001-8003, 8080, 9080, 9100──▶ app server   Prometheus scrapes; AlertManager → autopilot
#   app server ──3000, 9090, 9093, 3100, 4317──▶ obs server   nginx proxy, logs, traces, alert state
#
# Every rule names the SECURITY GROUP that may connect, not an address range.
# The rule this replaced on the app server was "all traffic from 10.0.0.0/16":
# anything that ever landed in the VPC could reach every port on the box, while
# the comment above it said "from the ALB only". A group reference keeps meaning
# what it says when instances are replaced and addresses change, and it is the
# only form that expresses "that role", which is what was intended.
#
# Why the rules are separate resources instead of inline `ingress {}` blocks:
# the app group must name the obs group and the obs group must name the app
# group. Written inline, each group needs the other's ID to be created, and
# Terraform reports a dependency cycle. As separate resources both groups are
# created empty first and the rules are attached afterwards.
#
# There is no port 22 anywhere. Access is through SSM Session Manager (ADR-002).

resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "Application Load Balancer: public HTTP(S) in, nginx on the app server out"
  vpc_id      = var.vpc_id

  tags = merge(var.common_tags, { Name = "${var.project_name}-alb-sg" })
}

resource "aws_security_group" "app" {
  name        = "${var.project_name}-app-sg"
  description = "Application server: nginx from the ALB, metrics and webhooks from the obs server"
  vpc_id      = var.vpc_id

  tags = merge(var.common_tags, { Name = "${var.project_name}-app-sg" })
}

resource "aws_security_group" "observability" {
  name        = "${var.project_name}-obs-sg"
  description = "Observability server: reachable only from the application server"
  vpc_id      = var.vpc_id

  tags = merge(var.common_tags, { Name = "${var.project_name}-obs-sg" })
}

# ─── ALB ──────────────────────────────────────────────────────────────────────
resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from the internet"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

# Only opened when there is a listener behind it. Without a domain there is no
# certificate and no HTTPS listener, so an open 443 would be a hole to nothing.
resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  count = var.enable_https ? 1 : 0

  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from the internet"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

# The load balancer has exactly one thing to reach: nginx on the app server,
# for both forwarded requests and its health check.
resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward and health-check nginx on the app server"
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
}

# ─── Application server ───────────────────────────────────────────────────────
resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "nginx from the ALB"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
}

# Prometheus pulls metrics, so the monitoring host must be able to open a
# connection to each service's own port. These ports are never reachable from
# the load balancer: users only ever get to nginx.
resource "aws_vpc_security_group_ingress_rule" "app_metrics_from_obs" {
  security_group_id            = aws_security_group.app.id
  description                  = "Prometheus scrapes secureship 8001, statusservice 8002, ragservice 8003"
  referenced_security_group_id = aws_security_group.observability.id
  ip_protocol                  = "tcp"
  from_port                    = 8001
  to_port                      = 8003
}

resource "aws_vpc_security_group_ingress_rule" "app_autopilot_from_obs" {
  security_group_id            = aws_security_group.app.id
  description                  = "AlertManager webhook and Prometheus scrape of the alert autopilot"
  referenced_security_group_id = aws_security_group.observability.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}

resource "aws_vpc_security_group_ingress_rule" "app_node_exporter_from_obs" {
  security_group_id            = aws_security_group.app.id
  description                  = "Prometheus scrapes host metrics (node-exporter)"
  referenced_security_group_id = aws_security_group.observability.id
  ip_protocol                  = "tcp"
  from_port                    = 9100
  to_port                      = 9100
}

resource "aws_vpc_security_group_ingress_rule" "app_alloy_from_obs" {
  security_group_id            = aws_security_group.app.id
  description                  = "Prometheus scrapes the log shipper (Alloy)"
  referenced_security_group_id = aws_security_group.observability.id
  ip_protocol                  = "tcp"
  from_port                    = 9080
  to_port                      = 9080
}

# Outbound is left open on both servers, deliberately and not because it is
# right: they pull images from ECR and Docker Hub, packages from Ubuntu mirrors,
# call SSM, DynamoDB, the LLM API and Slack. Closing it properly means VPC
# endpoints for the AWS services and an egress proxy with an allow-list for the
# rest. That is the next step for a system holding real data; see the README.
resource "aws_vpc_security_group_egress_rule" "app_all" {
  security_group_id = aws_security_group.app.id
  description       = "All outbound (not yet restricted, see the comment above)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ─── Observability server ─────────────────────────────────────────────────────
# Nothing outside the application server can reach this host at all: it has no
# public address, and these rules admit one security group.
locals {
  obs_ports_from_app = {
    grafana      = { port = 3000, why = "nginx proxies /grafana/ and deploy.sh posts deploy annotations" }
    prometheus   = { port = 9090, why = "nginx proxies /prometheus/ and chaos tooling reads alert state" }
    alertmanager = { port = 9093, why = "chaos tooling reads when an alert reached AlertManager" }
    loki         = { port = 3100, why = "the log shipper pushes logs and the autopilot queries them" }
    tempo_otlp   = { port = 4317, why = "the OpenTelemetry collector exports traces (OTLP gRPC)" }
  }
}

resource "aws_vpc_security_group_ingress_rule" "obs_from_app" {
  for_each = local.obs_ports_from_app

  security_group_id            = aws_security_group.observability.id
  description                  = each.value.why
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
}

resource "aws_vpc_security_group_egress_rule" "obs_all" {
  security_group_id = aws_security_group.observability.id
  description       = "All outbound (not yet restricted, same reasoning as the app server)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
