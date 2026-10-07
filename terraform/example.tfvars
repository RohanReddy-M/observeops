# ─── ObserveOps Terraform Variables Template ─────────────────────────────────
# Copy this to terraform.tfvars and fill in your values.
# terraform.tfvars is gitignored — this file is the safe shareable template.
#
# Required: admin_cidr
#   Get your IP: curl ifconfig.me
#   Then add /32: e.g. "203.0.113.42/32"

admin_cidr = "x.x.x.x/32" # REQUIRED: your IP as a /32. It gates direct access to Grafana on the obs server; there is no SSH
