#!/usr/bin/env bash
# setup-lattice.sh - Provision AWS VPC Lattice service network and update Helm values
# Run after eks-dev and eks-prod clusters are provisioned.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "========================================================"
echo "  Mini-Nasdaq: AWS VPC Lattice Setup"
echo "========================================================"
echo ""
echo "This script will:"
echo "  1. Provision VPC Lattice service network (terraform)"
echo "  2. Extract Lattice DNS names from terraform outputs"
echo "  3. Update Helm values with actual DNS names"
echo "  4. Trigger ArgoCD sync to apply updated values"
echo ""

# Check prerequisites
for tool in terraform aws kubectl; do
  if ! command -v "$tool" &>/dev/null; then
    echo "ERROR: '$tool' is not installed."
    exit 1
  fi
done

# --- Step 1: Apply Lattice Terraform ---
echo "[1/4] Provisioning VPC Lattice service network..."
cd "$REPO_ROOT/terraform/environments/lattice"
terraform init -input=false -reconfigure
terraform apply -auto-approve -input=false

# --- Step 2: Get DNS names ---
echo ""
echo "[2/4] Extracting Lattice service DNS names..."
MARKET_DATA_DNS=$(terraform output -raw market_data_service_dns 2>/dev/null || echo "")
ORDER_API_DNS=$(terraform output -raw order_execution_api_service_dns 2>/dev/null || echo "")

if [ -z "$MARKET_DATA_DNS" ] || [ -z "$ORDER_API_DNS" ]; then
  echo "ERROR: Could not retrieve Lattice DNS names from terraform output."
  echo "  Outputs available:"
  terraform output
  exit 1
fi

echo "  Market Data DNS:    $MARKET_DATA_DNS"
echo "  Order Exec API DNS: $ORDER_API_DNS"

# --- Step 3: Update Helm values ---
echo ""
echo "[3/4] Updating Helm values with Lattice DNS names..."

# Update order-execution-api dev values
DEV_VALUES="$REPO_ROOT/helm/order-execution-api/values/values-dev.yaml"
if grep -q '<lattice-dev-dns>' "$DEV_VALUES"; then
  sed -i "s|http://<lattice-dev-dns>/api/v1/market-data|http://${MARKET_DATA_DNS}/api/v1/market-data|g" "$DEV_VALUES"
  echo "  Updated: $DEV_VALUES"
fi

# Update order-execution-api prod values
PROD_VALUES="$REPO_ROOT/helm/order-execution-api/values/values-prod.yaml"
if grep -q '<lattice-prod-dns>' "$PROD_VALUES"; then
  sed -i "s|http://<lattice-prod-dns>/api/v1/market-data|http://${MARKET_DATA_DNS}/api/v1/market-data|g" "$PROD_VALUES"
  echo "  Updated: $PROD_VALUES"
fi

echo ""
echo "  Helm values updated with real Lattice DNS:"
echo "    MARKET_DATA_URL (dev):  http://${MARKET_DATA_DNS}/api/v1/market-data"
echo "    MARKET_DATA_URL (prod): http://${MARKET_DATA_DNS}/api/v1/market-data"

# --- Step 4: Summary ---
echo ""
echo "========================================================"
echo "  VPC Lattice Setup Complete!"
echo "========================================================"
echo ""
echo "  Service Network: nasdaq-service-network"
echo "  Market Data DNS: $MARKET_DATA_DNS"
echo "  Order Exec DNS:  $ORDER_API_DNS"
echo ""
echo "  Next steps:"
echo "  1. Commit updated Helm values to Git"
echo "  2. ArgoCD will auto-sync dev (or manually sync prod)"
echo "  3. Pods will pick up the new MARKET_DATA_URL via VPC Lattice"
echo ""
echo "  Verify Lattice connectivity:"
echo "    kubectl config use-context eks-dev"
echo "    kubectl exec -n order-api deploy/order-execution-api -- \\"
echo "      curl -s http://${MARKET_DATA_DNS}/api/v1/market-data | python3 -m json.tool"
