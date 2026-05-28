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

echo "==> Installing ArgoCD..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "==> Waiting for ArgoCD to be ready..."
kubectl wait --for=condition=available deployment/argocd-server \
  -n argocd --timeout=120s

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
