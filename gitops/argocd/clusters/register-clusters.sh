#!/usr/bin/env bash
# register-clusters.sh - Register EKS dev and prod clusters with ArgoCD
# Run from the management cluster context with ArgoCD CLI configured
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
ARGOCD_SERVER="${ARGOCD_SERVER:-}"
ARGOCD_USERNAME="${ARGOCD_USERNAME:-admin}"

echo "============================================"
echo " Mini-Nasdaq: Register Clusters with ArgoCD"
echo "============================================"

# --- Prerequisites check ---
for tool in aws kubectl argocd; do
  if ! command -v "$tool" &>/dev/null; then
    echo "ERROR: '$tool' is not installed or not in PATH"
    exit 1
  fi
done

# --- Step 1: Get kubeconfig for all clusters ---
echo ""
echo "[1/5] Fetching kubeconfigs..."
aws eks update-kubeconfig --region "$AWS_REGION" --name eks-mgmt --alias eks-mgmt
aws eks update-kubeconfig --region "$AWS_REGION" --name eks-dev  --alias eks-dev
aws eks update-kubeconfig --region "$AWS_REGION" --name eks-prod --alias eks-prod
echo "  Kubeconfigs updated for eks-mgmt, eks-dev, eks-prod"

# --- Step 2: Get ArgoCD server URL if not set ---
echo ""
echo "[2/5] Getting ArgoCD server URL..."
if [ -z "$ARGOCD_SERVER" ]; then
  kubectl config use-context eks-mgmt
  ARGOCD_SERVER=$(kubectl -n argocd get svc argocd-server \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || \
    kubectl -n argocd get svc argocd-server \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)

  if [ -z "$ARGOCD_SERVER" ]; then
    echo "ERROR: Could not determine ArgoCD server URL."
    echo "  Set ARGOCD_SERVER environment variable and re-run."
    exit 1
  fi
fi
echo "  ArgoCD server: $ARGOCD_SERVER"

# --- Step 3: Get ArgoCD admin password ---
echo ""
echo "[3/5] Getting ArgoCD admin password..."
kubectl config use-context eks-mgmt
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)

# --- Step 4: Login to ArgoCD ---
echo ""
echo "[4/5] Logging in to ArgoCD..."
argocd login "$ARGOCD_SERVER" \
  --username "$ARGOCD_USERNAME" \
  --password "$ARGOCD_PASSWORD" \
  --insecure \
  --grpc-web

echo "  Logged in as $ARGOCD_USERNAME"

# --- Step 5: Register clusters ---
echo ""
echo "[5/5] Registering clusters..."

# Register eks-dev
echo ""
echo "  Registering eks-dev..."
argocd cluster add eks-dev \
  --label env=dev \
  --label region="$AWS_REGION" \
  --label cluster=eks-dev \
  --name eks-dev \
  --yes

# Register eks-prod
echo ""
echo "  Registering eks-prod..."
argocd cluster add eks-prod \
  --label env=prod \
  --label region="$AWS_REGION" \
  --label cluster=eks-prod \
  --name eks-prod \
  --yes

# --- Verify ---
echo ""
echo "============================================"
echo " Cluster Registration Complete!"
echo "============================================"
echo ""
echo "Registered clusters:"
argocd cluster list

echo ""
echo "ArgoCD UI: https://$ARGOCD_SERVER"
echo "Username:  admin"
echo "Password:  $ARGOCD_PASSWORD"
echo ""
echo "Next: Apply ApplicationSets"
echo "  kubectl config use-context eks-mgmt"
echo "  kubectl apply -f gitops/argocd/applicationsets/"
