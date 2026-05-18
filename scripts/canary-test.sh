#!/usr/bin/env bash
# canary-test.sh - Demonstrate Argo Rollouts canary deployment with automated analysis
# Deploys a "broken" image version that returns HTTP 500 errors,
# then watches Argo Rollouts detect the error rate and automatically roll back.
set -euo pipefail

NAMESPACE="order-api"
ROLLOUT_NAME="order-execution-api"
STABLE_IMAGE="ghcr.io/YOUR_ORG/order-execution-api:stable"
BROKEN_IMAGE="ghcr.io/YOUR_ORG/order-execution-api:broken"

echo "========================================================"
echo "  Mini-Nasdaq: Canary Deployment + Auto-Rollback Demo"
echo "========================================================"
echo ""
echo "This script will:"
echo "  1. Switch context to eks-prod"
echo "  2. Deploy the 'broken' image (returns HTTP 500)"
echo "  3. Watch canary progress: 10% → analysis → automatic rollback"
echo ""
echo "The Argo Rollouts analysis will:"
echo "  - Check error rate every 30s"
echo "  - Fail if error rate > 5%"
echo "  - Auto-rollback after 3 consecutive failures"
echo ""
read -r -p "Press Enter to start the canary demo..."

# Switch to prod cluster
echo ""
echo "[1/4] Switching kubectl context to eks-prod..."
kubectl config use-context eks-prod

# Verify rollout exists
if ! kubectl get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" &>/dev/null; then
  echo "ERROR: Rollout '$ROLLOUT_NAME' not found in namespace '$NAMESPACE'."
  echo ""
  echo "  Apply rollout resources first:"
  echo "    kubectl config use-context eks-prod"
  echo "    kubectl apply -f gitops/rollouts/rollout-services.yaml"
  echo "    kubectl apply -f gitops/rollouts/analysis-template.yaml"
  echo "    kubectl apply -f gitops/rollouts/order-execution-api-rollout.yaml"
  exit 1
fi

# Show current rollout state
echo ""
echo "[2/4] Current rollout state:"
kubectl argo rollouts get rollout "$ROLLOUT_NAME" -n "$NAMESPACE"

# Deploy broken image
echo ""
echo "[3/4] Deploying 'broken' image to trigger canary..."
echo "  Setting image to: $BROKEN_IMAGE"
kubectl argo rollouts set image "$ROLLOUT_NAME" \
  "${ROLLOUT_NAME}=${BROKEN_IMAGE}" \
  -n "$NAMESPACE"

echo ""
echo "  Canary rollout started!"
echo "  Weight will reach 10%, then pause 60s, then run analysis."
echo "  The broken image returns HTTP 500 → analysis will fail → rollback."
echo ""

# Watch rollout
echo "[4/4] Watching rollout (press Ctrl+C to stop watching, rollback continues)..."
echo ""
echo "  Timeline:"
echo "    0:00 - Canary pods start (10% weight)"
echo "    1:00 - Analysis: error-rate-check begins"
echo "    ~2:00 - Analysis fails (error rate > 5%)"
echo "    ~2:30 - Automatic rollback to stable image"
echo ""

kubectl argo rollouts get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" --watch &
WATCH_PID=$!

# Give the rollout time to progress and roll back
sleep 240

# Stop watching
kill "$WATCH_PID" 2>/dev/null || true

echo ""
echo "========================================================"
echo "  Final rollout state:"
kubectl argo rollouts get rollout "$ROLLOUT_NAME" -n "$NAMESPACE"
echo ""
echo "  Stable image restored: $STABLE_IMAGE"
echo "========================================================"
echo ""
echo "Key observations:"
echo "  - The canary received 10% of traffic (canary service)"
echo "  - AnalysisRun 'error-rate-check' detected >5% error rate"
echo "  - Argo Rollouts automatically rolled back after 3 failures"
echo "  - Zero downtime: stable pods continued serving 90% of traffic"
echo ""
echo "  Check ArgoCD UI for the app status and rollout history."
