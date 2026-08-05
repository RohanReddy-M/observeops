#!/usr/bin/env bash
# ─── K8s Bootstrap ────────────────────────────────────────────────────────────
# Run this ONCE before ArgoCD deploys anything.
# Creates secrets that cannot be stored in git (they contain real API keys).
#
# Order matters:
#   1. Namespace  — everything else lives inside it
#   2. Secrets    — pods reference these; must exist before pods start
#   3. ArgoCD app — now safe to deploy (secrets already in place)
#
# Usage:
#   kubectl config use-context <your-eks-context>
#   bash kubernetes/bootstrap.sh

set -e

NAMESPACE=observeops
GROQ_KEY="${GROQ_API_KEY:-}"

if [ -z "$GROQ_KEY" ]; then
  echo "ERROR: Set GROQ_API_KEY before running this script."
  echo "  export GROQ_API_KEY=gsk_..."
  exit 1
fi

echo "==> Creating namespace..."
kubectl apply -f kubernetes/namespace.yaml

echo "==> Creating observeops-secrets (GROQ_API_KEY)..."
kubectl create secret generic observeops-secrets \
  --from-literal=GROQ_API_KEY="$GROQ_KEY" \
  --namespace "$NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Creating observeops-config (OTel endpoint)..."
OBS_IP=$(aws ssm get-parameter \
  --name "/observeops/production/obs_server_ip" \
  --query "Parameter.Value" --output text 2>/dev/null || \
  cd terraform && terraform output -raw obs_server_private_ip 2>/dev/null || echo "")
if [ -z "$OBS_IP" ]; then
  echo "  WARNING: Could not resolve obs server IP. OTel traces will not reach the collector."
  echo "  Set OBS_SERVER_IP manually: kubectl create configmap observeops-config --from-literal=OBS_SERVER_OTLP_ENDPOINT=http://<obs-ip>:4317 -n $NAMESPACE"
else
  kubectl create configmap observeops-config \
    --from-literal=OBS_SERVER_OTLP_ENDPOINT="http://${OBS_IP}:4317" \
    --namespace "$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "  OTel endpoint: http://${OBS_IP}:4317"
fi

echo "==> Installing ArgoCD..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "==> Waiting for ArgoCD to be ready..."
kubectl wait --for=condition=available deployment/argocd-server \
  -n argocd --timeout=120s

echo "==> Injecting ACM certificate ARN into ingress..."
ACM_CERT_ARN=$(cd terraform && terraform output -raw acm_certificate_arn 2>/dev/null || echo "")
if [ -n "$ACM_CERT_ARN" ]; then
  sed -i "s|__ACM_CERT_ARN__|${ACM_CERT_ARN}|g" kubernetes/ingress/ingress.yaml
  echo "  Cert ARN injected: ${ACM_CERT_ARN}"
else
  echo "  WARNING: Could not get cert ARN from Terraform. Ingress TLS will not work."
  echo "  Run: terraform -chdir=terraform output -raw acm_certificate_arn"
fi

echo "==> Bootstrapping App of Apps (sync waves will enforce deploy order)..."
kubectl apply -f kubernetes/argocd/project.yaml
kubectl apply -f kubernetes/argocd/app-of-apps.yaml

echo ""
echo "Done. ArgoCD will now sync in wave order:"
echo "  Wave 0: monitoring  (PVCs bind, Prometheus starts)"
echo "  Wave 1: secureship, statusservice  (stateless APIs)"
echo "  Wave 2: ragservice  (needs observeops-secrets)"
echo ""
echo "Watch progress:"
echo "  kubectl get applications -n argocd"
echo "  kubectl get pods -n observeops -w"
