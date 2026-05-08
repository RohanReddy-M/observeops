# ObserveOps — Kubernetes

Production-ready Kubernetes manifests for ObserveOps. Runs locally with `kind` for free; production-ready for EKS.

## Architecture

```
Internet → ALB (AWS Load Balancer Controller)
              ↓
         Ingress (path-based routing)
         ├── /ai/*      → ragservice   (1-3 pods, HPA on CPU)
         ├── /status/*  → statusservice (2 pods)
         └── /*         → secureship   (2-10 pods, HPA on CPU+memory)

Monitoring (same namespace, ClusterIP only):
  Prometheus → scrapes all pods
  Grafana    → dashboards (PVC-backed)
  Loki       → log aggregation (PVC-backed)
```

## Run Locally (free, no AWS needed)

**Prerequisites:** Docker, [kind](https://kind.sigs.k8s.io/), kubectl

```bash
# Create local cluster
kind create cluster --name observeops

# Apply everything
kubectl apply -f namespace.yaml
kubectl apply -f apps/secureship/
kubectl apply -f apps/statusservice/
kubectl apply -f apps/ragservice/
kubectl apply -f monitoring/prometheus/
kubectl apply -f monitoring/grafana/
kubectl apply -f monitoring/loki/

# Install nginx ingress for local routing
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

# Apply ingress (switch annotation to nginx first)
kubectl apply -f ingress/ingress.yaml

# Check everything is running
kubectl get pods -n observeops
kubectl get hpa -n observeops
```

## Deploy to EKS (production)

```bash
# Create cluster (~10 min)
eksctl create cluster -f eks/cluster.yaml

# Install AWS Load Balancer Controller
helm repo add eks https://aws.github.io/eks-charts
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=observeops \
  --set serviceAccount.create=false \
  --set serviceAccount.name=observeops-sa

# Deploy
kubectl apply -f namespace.yaml
kubectl apply -f apps/
kubectl apply -f monitoring/
kubectl apply -f ingress/ingress.yaml

# Watch rollout
kubectl rollout status deployment/secureship -n observeops
kubectl get hpa -n observeops --watch
```

## Key Design Decisions

| Decision | Why |
|---|---|
| HPA on CPU + memory | secureship is CPU-bound under load; ragservice is memory-bound due to PyTorch |
| Separate node group for AI | RAGService needs 2Gi+ memory — taints prevent other pods from wasting that capacity |
| Spot instances | 70% cost reduction; acceptable for stateless app pods |
| PVCs for Prometheus/Grafana/Loki | Metrics and logs must survive pod restarts |
| ClusterIP for all services | Never expose pods directly; all external traffic goes through the Ingress/ALB |
| Rolling update, maxUnavailable=0 | Zero-downtime deploys for stateless services |

## Auto-scaling Behavior

```
secureship:  2 pods baseline → scales to 10 at 70% CPU or 80% memory
ragservice:  1 pod baseline → scales to 3 at 80% CPU (slow scale-up: 2min window)
```

Scale-up is fast (30s window for secureship), scale-down is slow (5min window) to avoid thrashing.
