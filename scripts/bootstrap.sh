#!/usr/bin/env bash
# bootstrap.sh - Full Mini-Nasdaq GitOps Platform Bootstrap Script
# Run from the repo root directory.
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "========================================================"
echo "  Mini-Nasdaq GitOps Platform Bootstrap"
echo "  Repo: $REPO_ROOT"
echo "  AWS Region: $AWS_REGION"
echo "========================================================"

# --- Step 0: Prerequisites check ---
echo ""
echo "[0/7] Checking prerequisites..."
MISSING=()
for tool in aws kubectl helm terraform argocd; do
  if ! command -v "$tool" &>/dev/null; then
    MISSING+=("$tool")
  fi
done

if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "ERROR: Missing required tools: ${MISSING[*]}"
  echo ""
  echo "Install instructions:"
  echo "  aws cli   : https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"
  echo "  kubectl   : https://kubernetes.io/docs/tasks/tools/"
  echo "  helm      : https://helm.sh/docs/intro/install/"
  echo "  terraform : https://developer.hashicorp.com/terraform/downloads"
  echo "  argocd    : https://argo-cd.readthedocs.io/en/stable/cli_installation/"
  exit 1
fi

echo "  All prerequisites found."

# Check AWS credentials
echo ""
echo "  Verifying AWS credentials..."
AWS_IDENTITY=$(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null || true)
if [ -z "$AWS_IDENTITY" ]; then
  echo "ERROR: AWS credentials not configured or expired."
  echo "  Run: aws configure  OR  aws sso login"
  exit 1
fi
echo "  AWS identity: $AWS_IDENTITY"

# --- Step 1: Bootstrap Terraform state ---
echo ""
echo "[1/7] Bootstrapping Terraform state backend (S3 + DynamoDB)..."
cd "$REPO_ROOT/terraform/bootstrap"
terraform init -input=false
terraform apply -auto-approve -input=false
echo "  State backend ready: bucket=nasdaq-gitops-tfstate table=nasdaq-gitops-tf-locks"

# --- Step 2: Provision mgmt cluster ---
echo ""
echo "[2/7] Provisioning management cluster (eks-mgmt)..."
cd "$REPO_ROOT/terraform/environments/mgmt"
terraform init -input=false -reconfigure
terraform apply -auto-approve -input=false
echo "  eks-mgmt cluster provisioned."

# --- Step 3: Provision dev cluster ---
echo ""
echo "[3/7] Provisioning dev cluster (eks-dev)..."
cd "$REPO_ROOT/terraform/environments/dev"
terraform init -input=false -reconfigure
terraform apply -auto-approve -input=false
echo "  eks-dev cluster provisioned."

# --- Step 4: Provision prod cluster ---
echo ""
echo "[4/7] Provisioning prod cluster (eks-prod)..."
cd "$REPO_ROOT/terraform/environments/prod"
terraform init -input=false -reconfigure
terraform apply -auto-approve -input=false
echo "  eks-prod cluster provisioned."

# --- Step 5: Update kubeconfigs ---
echo ""
echo "[5/7] Updating kubeconfig for all clusters..."
aws eks update-kubeconfig --region "$AWS_REGION" --name eks-mgmt --alias eks-mgmt
aws eks update-kubeconfig --region "$AWS_REGION" --name eks-dev  --alias eks-dev
aws eks update-kubeconfig --region "$AWS_REGION" --name eks-prod --alias eks-prod
echo "  Kubeconfigs updated."

# --- Step 6: Install ArgoCD HA on mgmt ---
echo ""
echo "[6/7] Installing ArgoCD HA on eks-mgmt..."
kubectl config use-context eks-mgmt

# Add Helm repo
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update

# Install ArgoCD
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --values "$REPO_ROOT/gitops/argocd/install/argocd-ha-values.yaml" \
  --wait \
  --timeout 10m

echo "  ArgoCD installed. Waiting for server to be ready..."
kubectl rollout status deployment/argocd-server -n argocd --timeout=5m

# --- Step 7: Print results ---
echo ""
echo "[7/7] Getting ArgoCD access info..."
ARGOCD_URL=$(kubectl -n argocd get svc argocd-server \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || \
  kubectl -n argocd get svc argocd-server \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || \
  echo "pending")

ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d 2>/dev/null || echo "not-ready")

echo ""
echo "========================================================"
echo "  Bootstrap Complete!"
echo "========================================================"
echo ""
echo "  ArgoCD URL:      http://$ARGOCD_URL"
echo "  ArgoCD Username: admin"
echo "  ArgoCD Password: $ARGOCD_PASSWORD"
echo ""
echo "  Next steps:"
echo "  1. Register clusters:  ./scripts/register-clusters.sh"
echo "  2. Setup Lattice:      ./scripts/setup-lattice.sh"
echo "  3. Apply AppSets:      kubectl apply -f gitops/argocd/applicationsets/"
echo "  4. Install monitoring: ./monitoring/install-monitoring.sh"
echo ""
