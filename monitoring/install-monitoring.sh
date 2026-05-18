#!/usr/bin/env bash
# install-monitoring.sh - Install kube-prometheus-stack on the current cluster
# Run separately on each cluster (mgmt, dev, prod) as needed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NAMESPACE="monitoring"
RELEASE_NAME="monitoring"
CONTEXT="${1:-$(kubectl config current-context)}"

echo "========================================================"
echo "  Mini-Nasdaq: Install Prometheus + Grafana Monitoring"
echo "  Cluster context: $CONTEXT"
echo "========================================================"
echo ""

# Prerequisites
for tool in kubectl helm; do
  if ! command -v "$tool" &>/dev/null; then
    echo "ERROR: '$tool' is not installed."
    exit 1
  fi
done

# Set context
kubectl config use-context "$CONTEXT"
echo "  Active context: $(kubectl config current-context)"

# Add Helm repo
echo ""
echo "[1/4] Adding prometheus-community Helm repo..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update
echo "  Repo added/updated."

# Create namespace
echo ""
echo "[2/4] Creating monitoring namespace..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Install stack
echo ""
echo "[3/4] Installing kube-prometheus-stack..."
helm upgrade --install "$RELEASE_NAME" prometheus-community/kube-prometheus-stack \
  --namespace "$NAMESPACE" \
  --values "$REPO_ROOT/monitoring/prometheus-values.yaml" \
  --wait \
  --timeout 10m

echo "  kube-prometheus-stack installed."

# Get access info
echo ""
echo "[4/4] Getting Grafana access info..."
GRAFANA_URL=$(kubectl -n "$NAMESPACE" get svc "${RELEASE_NAME}-grafana" \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || \
  kubectl -n "$NAMESPACE" get svc "${RELEASE_NAME}-grafana" \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || \
  echo "pending")

PROMETHEUS_URL=$(kubectl -n "$NAMESPACE" get svc "${RELEASE_NAME}-kube-prometheus-prometheus" \
  -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "unknown")

echo ""
echo "========================================================"
echo "  Monitoring Stack Installed!"
echo "========================================================"
echo ""
echo "  Grafana URL:      http://$GRAFANA_URL"
echo "  Grafana Username: admin"
echo "  Grafana Password: nasdaq123"
echo ""
echo "  Prometheus (in-cluster): http://${PROMETHEUS_URL}:9090"
echo "    (or: kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090)"
echo ""
echo "  Useful dashboards (import by ID in Grafana):"
echo "    15386 - Argo Rollouts"
echo "    6336  - Kubernetes Pods"
echo "    13770 - FastAPI Prometheus"
echo ""
echo "  Port-forward alternative:"
echo "    kubectl port-forward -n monitoring svc/${RELEASE_NAME}-grafana 3000:80"
echo "    Open: http://localhost:3000 (admin / nasdaq123)"
