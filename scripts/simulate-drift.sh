#!/usr/bin/env bash
# simulate-drift.sh - Introduce configuration drift on the dev cluster
# This script scales the order-execution-api deployment out-of-band (outside of Git),
# then watches ArgoCD self-heal it back to the Git-declared state.
set -euo pipefail

NAMESPACE="order-api"
DEPLOYMENT="order-execution-api"
DRIFT_REPLICAS=5
WATCH_TIMEOUT=180  # seconds

echo "========================================================"
echo "  Mini-Nasdaq: Drift Detection Demo"
echo "========================================================"
echo ""
echo "This script will:"
echo "  1. Switch context to eks-dev"
echo "  2. Scale '$DEPLOYMENT' to $DRIFT_REPLICAS replicas (Git says 1)"
echo "  3. Watch ArgoCD detect and self-heal the drift (~3 min)"
echo ""
read -r -p "Press Enter to start the demo..."

# Switch to dev cluster
echo ""
echo "[1/3] Switching kubectl context to eks-dev..."
kubectl config use-context eks-dev

# Verify deployment exists
if ! kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" &>/dev/null; then
  echo "ERROR: Deployment '$DEPLOYMENT' not found in namespace '$NAMESPACE'."
  echo "  Make sure the application is deployed first via ArgoCD."
  exit 1
fi

CURRENT_REPLICAS=$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" \
  -o jsonpath='{.spec.replicas}')
echo "  Current replicas: $CURRENT_REPLICAS"

# Introduce drift
echo ""
echo "[2/3] Introducing drift: scaling to $DRIFT_REPLICAS replicas..."
kubectl scale deployment "$DEPLOYMENT" \
  -n "$NAMESPACE" \
  --replicas="$DRIFT_REPLICAS"

sleep 2

ACTUAL_REPLICAS=$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" \
  -o jsonpath='{.spec.replicas}')
echo ""
echo "  DRIFT INTRODUCED!"
echo "  Deployment '$DEPLOYMENT' now has $ACTUAL_REPLICAS replicas"
echo "  Git declares: 1 replica (dev environment)"
echo ""
echo "  In the ArgoCD UI, the app will show 'OutOfSync' shortly."
echo "  ArgoCD self-heal will restore it to 1 replica within ~3 minutes."
echo ""
echo "  ArgoCD dashboard: check Applications → order-execution-api-dev"
echo ""

# Watch the deployment for self-healing
echo "[3/3] Watching for ArgoCD self-heal (timeout: ${WATCH_TIMEOUT}s)..."
echo "  (ArgoCD's default reconciliation period is 3 minutes)"
echo ""

START_TIME=$(date +%s)
HEALED=false

while true; do
  CURRENT=$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
  ELAPSED=$(( $(date +%s) - START_TIME ))

  echo "  [${ELAPSED}s] Current replicas: $CURRENT  (target: 1)"

  if [ "$CURRENT" -eq 1 ]; then
    HEALED=true
    break
  fi

  if [ "$ELAPSED" -ge "$WATCH_TIMEOUT" ]; then
    break
  fi

  sleep 15
done

echo ""
if $HEALED; then
  echo "  Self-heal successful!"
  echo "  ArgoCD detected drift and restored '$DEPLOYMENT' to 1 replica."
else
  echo "  Timeout reached. Check ArgoCD dashboard for sync status."
  echo "  You can manually trigger sync: argocd app sync order-execution-api-dev"
fi

echo ""
echo "========================================================"
echo "  Current deployment state:"
kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE"
echo "========================================================"
