# Mini-Nasdaq GitOps Platform

A production-grade multi-cluster GitOps platform simulating a financial exchange infrastructure. This project demonstrates enterprise GitOps patterns using ArgoCD, Argo Rollouts, AWS VPC Lattice, Terraform, and Helm.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                     Management Cluster (eks-mgmt)               │
│  ┌─────────────┐  ┌──────────────┐  ┌───────────────────────┐  │
│  │   ArgoCD    │  │  Prometheus  │  │      Grafana           │  │
│  │  (HA Mode)  │  │   Stack      │  │   (Dashboards)        │  │
│  └──────┬──────┘  └──────────────┘  └───────────────────────┘  │
│         │ manages                                                │
└─────────┼───────────────────────────────────────────────────────┘
          │
    ┌─────┴──────────────────────────────┐
    │                                    │
    ▼                                    ▼
┌─────────────────────┐      ┌─────────────────────┐
│   Dev Cluster       │      │   Prod Cluster      │
│   (eks-dev)         │      │   (eks-prod)        │
│                     │      │                     │
│ ┌─────────────────┐ │      │ ┌─────────────────┐ │
│ │ order-exec-api  │ │      │ │ order-exec-api  │ │
│ │ (1 replica)     │ │      │ │ (3+ replicas)   │ │
│ └─────────────────┘ │      │ │ Canary Rollout  │ │
│ ┌─────────────────┐ │      │ └─────────────────┘ │
│ │market-data-svc  │ │      │ ┌─────────────────┐ │
│ └─────────────────┘ │      │ │market-data-svc  │ │
│                     │      │ └─────────────────┘ │
└──────────┬──────────┘      └──────────┬──────────┘
           │                            │
           └────────────┬───────────────┘
                        │
              ┌─────────▼──────────┐
              │   AWS VPC Lattice  │
              │  Service Network   │
              │ ┌────────────────┐ │
              │ │ market-data    │ │
              │ │   service      │ │
              │ └────────────────┘ │
              │ ┌────────────────┐ │
              │ │ order-exec-api │ │
              │ └────────────────┘ │
              └────────────────────┘
```

## Four Phases

### Phase 1: Infrastructure (Terraform)
Provision three EKS clusters (mgmt, dev, prod) with VPCs, IAM roles, and IRSA.

### Phase 2: GitOps Control Plane (ArgoCD HA)
Deploy ArgoCD in HA mode on the management cluster, register dev/prod clusters.

### Phase 3: Application Delivery (Helm + ApplicationSets)
Deploy order-execution-api and market-data-service via ApplicationSets with environment-specific values.

### Phase 4: Advanced Patterns
- Canary deployments with Argo Rollouts and automated analysis
- Cross-cluster service mesh via AWS VPC Lattice
- Drift detection and self-healing
- Sync windows to block prod deployments during market hours

---

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| AWS CLI | >= 2.x | [docs.aws.amazon.com](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) |
| Terraform | >= 1.7.0 | [developer.hashicorp.com](https://developer.hashicorp.com/terraform/downloads) |
| kubectl | >= 1.29 | [kubernetes.io](https://kubernetes.io/docs/tasks/tools/) |
| Helm | >= 3.14 | [helm.sh](https://helm.sh/docs/intro/install/) |
| ArgoCD CLI | >= 2.10 | [argo-cd.readthedocs.io](https://argo-cd.readthedocs.io/en/stable/cli_installation/) |
| Argo Rollouts Plugin | >= 1.7 | `kubectl argo rollouts version` |

### AWS Permissions Required
Your AWS IAM user/role needs:
- `eks:*`
- `ec2:*` (VPC, subnets, IGW, NAT, route tables)
- `iam:*` (roles, policies, OIDC providers)
- `s3:*` (state bucket)
- `dynamodb:*` (lock table)
- `vpc-lattice:*`

---

## Phase 1: Infrastructure Provisioning

### Step 1.1: Bootstrap Terraform State Backend

```bash
cd terraform/bootstrap
terraform init
terraform apply -auto-approve
```

This creates:
- S3 bucket `nasdaq-gitops-tfstate` with versioning and encryption
- DynamoDB table `nasdaq-gitops-tf-locks` for state locking

### Step 1.2: Provision Management Cluster

```bash
cd terraform/environments/mgmt
terraform init
terraform apply -auto-approve
```

### Step 1.3: Provision Dev Cluster

```bash
cd terraform/environments/dev
terraform init
terraform apply -auto-approve
```

### Step 1.4: Provision Prod Cluster

```bash
cd terraform/environments/prod
terraform init
terraform apply -auto-approve
```

### Step 1.5: Update Kubeconfig

```bash
aws eks update-kubeconfig --region us-east-1 --name eks-mgmt --alias eks-mgmt
aws eks update-kubeconfig --region us-east-1 --name eks-dev  --alias eks-dev
aws eks update-kubeconfig --region us-east-1 --name eks-prod --alias eks-prod
```

**Or run the bootstrap script:**

```bash
chmod +x scripts/bootstrap.sh
./scripts/bootstrap.sh
```

---

## Phase 2: GitOps Control Plane

### Step 2.1: Install ArgoCD HA on Management Cluster

```bash
kubectl config use-context eks-mgmt

helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --values gitops/argocd/install/argocd-ha-values.yaml \
  --wait
```

### Step 2.2: Get ArgoCD Admin Password

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

### Step 2.3: Access ArgoCD UI

```bash
# Get the LoadBalancer URL
kubectl -n argocd get svc argocd-server

# Port-forward alternative
kubectl port-forward svc/argocd-server -n argocd 8080:80
# Open: http://localhost:8080 (admin / <password above>)
```

### Step 2.4: Register Dev and Prod Clusters

```bash
# Login to ArgoCD CLI
argocd login <ARGOCD_SERVER_URL> --username admin --password <PASSWORD> --insecure

# Register clusters
argocd cluster add eks-dev --label env=dev --label region=us-east-1
argocd cluster add eks-prod --label env=prod --label region=us-east-1

# Verify
argocd cluster list
```

**Or use the register script:**

```bash
chmod +x gitops/argocd/clusters/register-clusters.sh
./gitops/argocd/clusters/register-clusters.sh
```

---

## Phase 3: Application Delivery

### Step 3.1: Install Argo Rollouts (on dev and prod)

```bash
for ctx in eks-dev eks-prod; do
  kubectl config use-context $ctx
  kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
done
```

### Step 3.2: Apply ApplicationSets

```bash
kubectl config use-context eks-mgmt

# Deploy order-execution-api to both clusters
kubectl apply -f gitops/argocd/applicationsets/order-execution-api-appset.yaml

# Watch sync status
argocd app list
```

### Step 3.3: Verify Deployments

```bash
# Check dev
kubectl config use-context eks-dev
kubectl get pods -n order-api
kubectl get pods -n market-data

# Check prod
kubectl config use-context eks-prod
kubectl get pods -n order-api
kubectl get pods -n market-data
```

---

## Phase 4: Advanced Patterns

### 4A: Canary Deployment with Argo Rollouts

**Apply rollout resources on prod:**

```bash
kubectl config use-context eks-prod
kubectl apply -f gitops/rollouts/rollout-services.yaml
kubectl apply -f gitops/rollouts/analysis-template.yaml
kubectl apply -f gitops/rollouts/order-execution-api-rollout.yaml
```

**Run the canary test (deploys a "broken" version):**

```bash
chmod +x scripts/canary-test.sh
./scripts/canary-test.sh
```

Watch the rollout automatically pause at 10% weight when the error rate exceeds 5%, then roll back.

### 4B: Drift Detection Demo

```bash
chmod +x scripts/simulate-drift.sh
./scripts/simulate-drift.sh
```

This scales the dev deployment out-of-band. ArgoCD detects the drift and self-heals within ~3 minutes (default reconciliation period).

### 4C: AWS VPC Lattice Service Mesh

```bash
chmod +x scripts/setup-lattice.sh
./scripts/setup-lattice.sh
```

This provisions the VPC Lattice service network and updates the Helm values with actual Lattice DNS names.

### 4D: Sync Window (Prod Market Hours Block)

The prod ApplicationSet includes a sync window that **blocks deployments during market hours**:
- Monday–Friday: 09:30–16:00 ET (14:30–21:00 UTC)
- Only manual overrides by cluster-admins are allowed during this window

Verify in ArgoCD UI: Applications → order-execution-api-prod → Sync Windows

---

## Monitoring

### Install Prometheus + Grafana

```bash
chmod +x monitoring/install-monitoring.sh
./monitoring/install-monitoring.sh
```

### Access Grafana

```bash
kubectl -n monitoring get svc monitoring-grafana
# Default credentials: admin / nasdaq123
```

### Key Metrics
- `http_requests_total{app="order-execution-api"}` — request rate
- `http_request_duration_seconds` — latency percentiles
- Argo Rollouts dashboard: shows stable vs canary traffic split

---

## Repository Structure

```
mini-nasdaq-gitops/
├── terraform/
│   ├── bootstrap/          # S3 + DynamoDB for TF state
│   ├── modules/
│   │   ├── vpc/            # VPC module
│   │   ├── eks/            # EKS + IRSA module
│   │   └── lattice/        # VPC Lattice module
│   └── environments/
│       ├── mgmt/           # Management cluster
│       ├── dev/            # Dev cluster
│       ├── prod/           # Prod cluster
│       └── lattice/        # Lattice service network
├── gitops/
│   ├── argocd/
│   │   ├── install/        # ArgoCD HA Helm values
│   │   ├── clusters/       # Cluster registration
│   │   └── applicationsets/ # ApplicationSet manifests
│   └── rollouts/           # Argo Rollouts resources
├── helm/
│   ├── order-execution-api/ # Order API Helm chart
│   └── market-data-service/ # Market data Helm chart
├── services/
│   ├── order-execution-api/ # FastAPI service
│   └── market-data-service/ # FastAPI service
├── monitoring/             # Prometheus + Grafana
└── scripts/                # Automation scripts
```

---

## Cost Estimate (AWS us-east-1)

| Resource | Count | Monthly Cost |
|----------|-------|-------------|
| EKS Clusters | 3 | ~$0.10/hr × 3 = ~$216 |
| EC2 t3.medium (nodes) | 6 (2 per cluster) | ~$0.0416/hr × 6 = ~$180 |
| NAT Gateways | 6 (2 per cluster) | ~$0.045/hr × 6 = ~$195 |
| VPC Lattice | Per request | ~$10-50 (demo usage) |
| **Total** | | **~$600-650/month** |

> **Tip:** Run `terraform destroy` in each environment when not in use to avoid costs.

---

## Cleanup

```bash
# Destroy in reverse order
cd terraform/environments/lattice && terraform destroy -auto-approve
cd terraform/environments/prod    && terraform destroy -auto-approve
cd terraform/environments/dev     && terraform destroy -auto-approve
cd terraform/environments/mgmt    && terraform destroy -auto-approve
# Keep bootstrap (or destroy if done):
cd terraform/bootstrap            && terraform destroy -auto-approve
```

---

## Troubleshooting

### ArgoCD app stuck in Progressing
```bash
argocd app get <app-name> --refresh
kubectl describe rollout order-execution-api -n order-api
```

### Cluster not registered
```bash
argocd cluster list
kubectl get secret -n argocd -l argocd.argoproj.io/secret-type=cluster
```

### Lattice DNS not resolving
Ensure the VPC associations are active and the EKS worker node security groups allow traffic from the Lattice service network prefix list.

### Terraform state lock
```bash
# If apply fails with lock error:
terraform force-unlock <LOCK_ID>
```
