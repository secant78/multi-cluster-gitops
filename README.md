# Mini-Nasdaq GitOps Platform

A production-grade, multi-cluster GitOps deployment platform simulating a financial-grade exchange infrastructure. Built with Terraform, Argo CD (HA), AWS VPC Lattice, Argo Rollouts, and Helm — deployed across three isolated EKS clusters to demonstrate enterprise-level GitOps, progressive delivery, drift remediation, and cross-VPC service networking without peering.

---

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [Architecture](#2-architecture)
   - [Cluster Topology](#cluster-topology)
   - [Network Layout](#network-layout)
   - [GitOps Control Flow](#gitops-control-flow)
   - [VPC Lattice Service Mesh](#vpc-lattice-service-mesh)
3. [Repository Structure](#3-repository-structure)
4. [Phase 1 — Terraform Infrastructure](#4-phase-1--terraform-infrastructure)
   - [State Management](#state-management)
   - [VPC Module](#vpc-module)
   - [EKS Module](#eks-module)
   - [IRSA Design](#irsa-design)
5. [Phase 2 — Argo CD Multi-Cluster GitOps](#5-phase-2--argo-cd-multi-cluster-gitops)
   - [HA Architecture](#ha-architecture)
   - [Cluster Registration](#cluster-registration)
   - [ApplicationSets](#applicationsets)
   - [Sync Policies & Sync Windows](#sync-policies--sync-windows)
6. [Phase 3 — AWS VPC Lattice](#6-phase-3--aws-vpc-lattice)
   - [Why Not VPC Peering](#why-not-vpc-peering)
   - [Lattice Components](#lattice-components)
   - [Layer 7 Routing](#layer-7-routing)
7. [Phase 4 — Observability, Drift & Rollbacks](#7-phase-4--observability-drift--rollbacks)
   - [Drift Detection & Self-Heal](#drift-detection--self-heal)
   - [Canary Rollouts](#canary-rollouts)
   - [Analysis Templates](#analysis-templates)
8. [The Services](#8-the-services)
   - [Order Execution API](#order-execution-api)
   - [Market Data Service](#market-data-service)
9. [Helm Charts](#9-helm-charts)
10. [Monitoring Stack](#10-monitoring-stack)
11. [Prerequisites & Setup](#11-prerequisites--setup)
12. [Deployment Guide](#12-deployment-guide)
13. [Demo Playbook](#13-demo-playbook)
14. [Cost Estimate](#14-cost-estimate)
15. [Cleanup](#15-cleanup)
16. [Troubleshooting](#16-troubleshooting)
17. [Key Design Decisions](#17-key-design-decisions)
18. [Glossary](#18-glossary)

---

## 1. Project Overview

This platform simulates the infrastructure concerns of a capital markets trading firm operating under strict deployment governance. It addresses three real-world engineering challenges:

| Challenge | Solution |
|---|---|
| Multi-environment consistency with zero config drift | Argo CD GitOps with self-heal and ApplicationSets |
| Deploying to prod clusters without VPC peering or sidecars | AWS VPC Lattice Layer 7 service network |
| Preventing bad deploys from reaching prod users | Argo Rollouts canary with automated Prometheus analysis |
| Blocking deployments during NYSE trading hours | Argo CD Sync Windows on the prod application |
| Least-privilege pod identity on EKS | IRSA (IAM Roles for Service Accounts) on all clusters |

The three clusters simulate distinct organizational domains:

| Cluster | Role | VPC CIDR | Sync Policy |
|---|---|---|---|
| `eks-mgmt` | Houses Argo CD HA, runs no workloads | 10.0.0.0/16 | N/A |
| `eks-dev` | Development runtime, rapid iteration | 10.1.0.0/16 | Auto-sync + Self-heal |
| `eks-prod` | Simulated trading/capital markets production | 10.2.0.0/16 | Manual gate + Sync Window |

---

## 2. Architecture

### Cluster Topology

```
┌──────────────────────────────────────────────────────────────────────────┐
│                   VPC: 10.0.0.0/16  (Management)                        │
│                                                                          │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │                    eks-mgmt  (EKS 1.29)                             │ │
│  │                                                                     │ │
│  │  ┌──────────────────────┐  ┌─────────────┐  ┌──────────────────┐  │ │
│  │  │   Argo CD HA         │  │  Prometheus │  │    Grafana       │  │ │
│  │  │  ┌────────────────┐  │  │   Stack     │  │  (Dashboards)    │  │ │
│  │  │  │ App Controller │  │  └─────────────┘  └──────────────────┘  │ │
│  │  │  │  (sharded x2)  │  │                                         │ │
│  │  │  ├────────────────┤  │                                         │ │
│  │  │  │  Repo Server   │  │                                         │ │
│  │  │  │   (x2 pods)    │  │                                         │ │
│  │  │  ├────────────────┤  │                                         │ │
│  │  │  │   API Server   │  │                                         │ │
│  │  │  │   (x2 pods)    │  │                                         │ │
│  │  │  ├────────────────┤  │                                         │ │
│  │  │  │  Redis HA      │  │                                         │ │
│  │  │  │ (Sentinel x3)  │  │                                         │ │
│  │  │  └────────────────┘  │                                         │ │
│  │  └──────────┬───────────┘                                         │ │
│  │             │  manages (Kubernetes API)                            │ │
│  └─────────────┼───────────────────────────────────────────────────--┘ │
└────────────────┼─────────────────────────────────────────────────────---┘
                 │
        ┌────────┴────────┐
        │                 │
        ▼                 ▼
┌───────────────┐   ┌───────────────┐
│ VPC:          │   │ VPC:          │
│ 10.1.0.0/16   │   │ 10.2.0.0/16   │
│               │   │               │
│  eks-dev      │   │  eks-prod     │
│               │   │               │
│ ┌───────────┐ │   │ ┌───────────┐ │
│ │order-api  │ │   │ │order-api  │ │
│ │(1 replica)│ │   │ │(3 replica)│ │
│ │debug logs │ │   │ │Rollout +  │ │
│ │auto-sync  │ │   │ │CanaryStep │ │
│ └───────────┘ │   │ └───────────┘ │
│ ┌───────────┐ │   │ ┌───────────┐ │
│ │market-data│ │   │ │market-data│ │
│ │(2 replica)│ │   │ │(3 replica)│ │
│ └───────────┘ │   │ └───────────┘ │
└───────┬───────┘   └───────┬───────┘
        │                   │
        └─────────┬─────────┘
                  │  (No VPC Peering — AWS VPC Lattice only)
         ┌────────▼────────────┐
         │  VPC Lattice        │
         │  Service Network    │
         │  nasdaq-service-net │
         │                     │
         │  ┌───────────────┐  │
         │  │ market-data   │  │
         │  │ service       │  │
         │  │ (L7 routing)  │  │
         │  └───────────────┘  │
         │  ┌───────────────┐  │
         │  │ order-exec    │  │
         │  │ api service   │  │
         │  └───────────────┘  │
         └─────────────────────┘
```

### Network Layout

Each VPC follows an identical subnet pattern to allow the module to be reused across all environments:

```
VPC (e.g. 10.1.0.0/16)
├── Public Subnet A  (10.1.0.0/24)  — us-east-1a  → Internet-facing NLBs
├── Public Subnet B  (10.1.1.0/24)  — us-east-1b  → Internet-facing NLBs
├── Private Subnet A (10.1.2.0/24)  — us-east-1a  → EKS worker nodes
└── Private Subnet B (10.1.3.0/24)  — us-east-1b  → EKS worker nodes

Public subnets:  tagged kubernetes.io/role/elb=1
Private subnets: tagged kubernetes.io/role/internal-elb=1
                 tagged kubernetes.io/cluster/<name>=owned
```

Two NAT Gateways (one per AZ) provide HA egress for worker nodes. Nodes live in private subnets and have no direct internet exposure.

### GitOps Control Flow

```
Developer pushes → GitHub (this repo)
                        │
                        │  Argo CD polls every 3m (or webhook)
                        ▼
                  Argo CD (eks-mgmt)
                  ┌─────────────────┐
                  │ ApplicationSet  │
                  │  Generator      │
                  │                 │
                  │ eks-dev  (env=dev)  ──→  Auto-sync
                  │ eks-prod (env=prod) ──→  Manual gate
                  └─────────────────┘
                        │
             ┌──────────┴──────────┐
             ▼                     ▼
        eks-dev                eks-prod
     (auto-applies)        (waits for approval
                            outside Sync Window)
```

### VPC Lattice Service Mesh

```
order-execution-api (eks-prod)
        │
        │  GET http://<lattice-dns>/api/v1/market-data/AAPL
        │  (plain HTTP — Lattice handles TLS termination at border)
        ▼
AWS VPC Lattice Service Network
        │
        │  Path-based routing: /api/v1/market-data/* → market-data target group
        │  Health checks: GET /health (HTTP 200 required)
        ▼
market-data-service (eks-dev)
        │
        └── Returns: { symbol, bid, ask, last_price, volume, timestamp }
```

No VPC peering. No Transit Gateway. No Istio sidecar. Lattice handles auth, routing, and health at the AWS network layer.

---

## 3. Repository Structure

```
mini-nasdaq-gitops/
│
├── terraform/
│   ├── bootstrap/                  # Run once: creates S3 + DynamoDB for TF state
│   │   └── main.tf
│   │
│   ├── modules/                    # Reusable Terraform modules
│   │   ├── vpc/                    # VPC, subnets, IGW, NAT, route tables
│   │   │   ├── main.tf
│   │   │   ├── variables.tf
│   │   │   └── outputs.tf
│   │   ├── eks/                    # EKS cluster, node groups, IRSA OIDC
│   │   │   ├── main.tf
│   │   │   ├── variables.tf
│   │   │   └── outputs.tf
│   │   └── lattice/                # VPC Lattice: service network, services, routing
│   │       ├── main.tf
│   │       ├── variables.tf
│   │       └── outputs.tf
│   │
│   └── environments/               # One directory = one isolated TF state
│       ├── mgmt/                   # eks-mgmt: 10.0.0.0/16
│       ├── dev/                    # eks-dev:  10.1.0.0/16
│       ├── prod/                   # eks-prod: 10.2.0.0/16
│       └── lattice/                # VPC Lattice service network
│
├── gitops/
│   ├── argocd/
│   │   ├── install/
│   │   │   ├── namespace.yaml              # argocd namespace
│   │   │   ├── argocd-ha-values.yaml       # Helm values for HA deployment
│   │   │   └── kustomization.yaml
│   │   ├── clusters/
│   │   │   ├── eks-dev-secret.yaml         # Cluster registration secret (envsubst)
│   │   │   ├── eks-prod-secret.yaml
│   │   │   └── register-clusters.sh        # Automated cluster registration
│   │   └── applicationsets/
│   │       └── order-execution-api-appset.yaml  # Two ApplicationSets (dev + prod)
│   │
│   └── rollouts/
│       ├── order-execution-api-rollout.yaml    # 8-step canary Rollout
│       ├── analysis-template.yaml              # 3 Prometheus metrics
│       └── rollout-services.yaml               # Stable + canary Service pair
│
├── helm/
│   ├── order-execution-api/
│   │   ├── Chart.yaml
│   │   ├── values.yaml                    # Default values
│   │   ├── values/
│   │   │   ├── values-dev.yaml            # Dev overrides (1 replica, debug logging)
│   │   │   └── values-prod.yaml           # Prod overrides (3 replicas, HPA enabled)
│   │   └── templates/
│   │       ├── _helpers.tpl
│   │       ├── deployment.yaml
│   │       ├── service.yaml
│   │       ├── hpa.yaml
│   │       └── serviceaccount.yaml
│   │
│   └── market-data-service/
│       ├── Chart.yaml
│       ├── values.yaml
│       ├── values/
│       │   ├── values-dev.yaml
│       │   └── values-prod.yaml
│       └── templates/
│           ├── _helpers.tpl
│           ├── deployment.yaml
│           └── service.yaml
│
├── services/
│   ├── order-execution-api/        # FastAPI: order CRUD + market-data consumer
│   │   ├── main.py
│   │   ├── requirements.txt
│   │   └── Dockerfile
│   └── market-data-service/        # FastAPI: mock real-time quote feed
│       ├── main.py
│       ├── requirements.txt
│       └── Dockerfile
│
├── monitoring/
│   ├── prometheus-values.yaml      # kube-prometheus-stack Helm values
│   └── install-monitoring.sh
│
├── scripts/
│   ├── bootstrap.sh                # Full end-to-end provisioning
│   ├── simulate-drift.sh           # Phase 4: trigger out-of-band drift
│   ├── canary-test.sh              # Phase 4: deploy broken image, watch rollback
│   └── setup-lattice.sh            # Phase 3: provision Lattice + patch Helm values
│
├── .gitignore
└── README.md
```

---

## 4. Phase 1 — Terraform Infrastructure

### State Management

Before provisioning any clusters, a shared state backend must exist. Run `terraform/bootstrap/main.tf` once:

```bash
cd terraform/bootstrap
terraform init
terraform apply -auto-approve
```

This creates:

| Resource | Name | Purpose |
|---|---|---|
| S3 Bucket | `nasdaq-gitops-tfstate` | Stores all `.tfstate` files |
| S3 Versioning | enabled | Allows rollback of state files |
| S3 Encryption | AES256 (SSE-S3) | Encrypts state at rest |
| S3 Public Access Block | all blocked | Prevents accidental exposure |
| DynamoDB Table | `nasdaq-gitops-tf-locks` | Prevents concurrent `terraform apply` |
| DynamoDB Billing | PAY_PER_REQUEST | No capacity planning needed |

Each environment uses a unique state key:

```hcl
# terraform/environments/mgmt/backend.tf
backend "s3" {
  bucket         = "nasdaq-gitops-tfstate"
  key            = "mgmt/terraform.tfstate"   # ← unique per environment
  region         = "us-east-1"
  encrypt        = true
  dynamodb_table = "nasdaq-gitops-tf-locks"
}
```

State isolation means a `terraform destroy` in `dev/` cannot accidentally affect `prod/` state.

### VPC Module

Located at `terraform/modules/vpc/`, called by each environment with different CIDRs:

```hcl
module "vpc" {
  source = "../../modules/vpc"

  vpc_name             = "eks-dev-vpc"
  cidr_block           = "10.1.0.0/16"
  private_subnet_cidrs = ["10.1.2.0/24", "10.1.3.0/24"]
  public_subnet_cidrs  = ["10.1.0.0/24", "10.1.1.0/24"]
  availability_zones   = ["us-east-1a", "us-east-1b"]
}
```

Resources created per VPC:

- `aws_vpc` with DNS hostnames and resolution enabled
- 2 public subnets + 2 private subnets across separate AZs
- Internet Gateway attached to the VPC
- 2 Elastic IPs + 2 NAT Gateways (one per AZ for HA egress)
- Public route table: `0.0.0.0/0 → IGW`
- Private route table (per AZ): `0.0.0.0/0 → NAT Gateway`
- Subnet tags for AWS Load Balancer Controller to discover subnets automatically

### EKS Module

Located at `terraform/modules/eks/`. Key design choices:

**Cluster IAM Role** — attached policies:
- `AmazonEKSClusterPolicy`

**Node Group IAM Role** — attached policies:
- `AmazonEKSWorkerNodePolicy`
- `AmazonEKS_CNI_Policy`
- `AmazonEC2ContainerRegistryReadOnly`

**Node Group configuration:**
```hcl
instance_types  = ["t3.medium"]
desired_size    = 2
min_size        = 1
max_size        = 3
disk_size       = 20  # GB
```

Nodes live in private subnets only. The EKS API endpoint has `endpoint_private_access = true`.

**EKS Add-ons** managed by Terraform (not helm):
- `vpc-cni` — pod networking
- `kube-proxy` — service routing
- `coredns` — cluster DNS

### IRSA Design

IRSA (IAM Roles for Service Accounts) allows pods to assume AWS IAM roles without node-level credentials. The module provisions the OIDC provider automatically:

```hcl
# Fetch OIDC thumbprint
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

# Create OIDC identity provider
resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
}
```

Services can then be granted IAM roles scoped to a specific Kubernetes service account and namespace:

```json
{
  "Condition": {
    "StringEquals": {
      "oidc.eks.us-east-1.amazonaws.com/id/XXXX:sub":
        "system:serviceaccount:order-api:order-execution-api"
    }
  }
}
```

This means a compromised pod in `market-data` namespace cannot use the credentials of a pod in `order-api` namespace.

---

## 5. Phase 2 — Argo CD Multi-Cluster GitOps

### HA Architecture

Argo CD is deployed to `eks-mgmt` using the official Helm chart with HA values defined in `gitops/argocd/install/argocd-ha-values.yaml`.

```
eks-mgmt / namespace: argocd
│
├── argocd-application-controller  (StatefulSet, 2 replicas, sharded)
│     Uses consistent-hashing sharding algorithm. Each controller
│     shard is responsible for a subset of Application resources,
│     preventing a single controller from becoming a bottleneck.
│
├── argocd-repo-server             (Deployment, 2 replicas)
│     Clones Git repos and generates manifests (Helm, Kustomize).
│     Stateless — safe to scale horizontally.
│
├── argocd-server                  (Deployment, 2 replicas)
│     Serves the UI and gRPC/REST API. Stateless.
│
├── argocd-applicationset-controller (Deployment, 2 replicas)
│     Watches ApplicationSet CRDs and generates Application objects.
│
└── redis-ha                       (StatefulSet, 3 replicas + 3 Sentinels)
      Provides distributed caching for Argo CD's state. Sentinel
      handles automatic failover if the primary Redis goes down.
```

Key HA values:

```yaml
redis-ha:
  enabled: true

controller:
  replicas: 2
  env:
    - name: ARGOCD_CONTROLLER_SHARDING_ALGORITHM
      value: consistent-hashing

server:
  replicas: 2

repoServer:
  replicas: 2

applicationSet:
  replicas: 2
```

### Cluster Registration

Spoke clusters (`eks-dev`, `eks-prod`) are registered into the hub Argo CD as Kubernetes secrets in the `argocd` namespace. The secret must carry the label `argocd.argoproj.io/secret-type=cluster` and environment labels used by ApplicationSet generators.

```yaml
# gitops/argocd/clusters/eks-dev-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: eks-dev-cluster
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
    env: dev
    region: us-east-1
type: Opaque
stringData:
  name: eks-dev
  server: ${EKS_DEV_URL}
  config: |
    {
      "bearerToken": "${EKS_DEV_TOKEN}",
      "tlsClientConfig": {
        "caData": "${EKS_DEV_CA}"
      }
    }
```

The `register-clusters.sh` script automates extraction and application of these secrets using `aws eks describe-cluster` and `argocd cluster add`.

Alternatively, use the Argo CD CLI directly:

```bash
argocd cluster add eks-dev \
  --label env=dev \
  --label region=us-east-1 \
  --name eks-dev
```

Verify registration:

```bash
argocd cluster list
# NAME      SERVER                                  VERSION  STATUS   MESSAGE
# eks-dev   https://XXXX.gr7.us-east-1.eks.amazonaws.com  1.29     Successful
# eks-prod  https://YYYY.gr7.us-east-1.eks.amazonaws.com  1.29     Successful
```

### ApplicationSets

The file `gitops/argocd/applicationsets/order-execution-api-appset.yaml` contains **two ApplicationSet resources** separated by `---`. This approach was chosen over a single ApplicationSet with a cluster generator because it allows completely different `syncPolicy` configurations per environment — something a single templated ApplicationSet cannot cleanly express.

**Dev ApplicationSet** — auto-sync with self-heal:

```yaml
syncPolicy:
  automated:
    selfHeal: true    # Argo CD corrects any out-of-band drift
    prune: true       # Deletes resources removed from Git
  syncOptions:
    - CreateNamespace=true
    - ServerSideApply=true    # Uses SSA to avoid field manager conflicts
    - ApplyOutOfSyncOnly=true # Only syncs resources that have changed
  retry:
    limit: 5
    backoff:
      duration: 5s
      factor: 2
      maxDuration: 3m
```

**Prod ApplicationSet** — manual gate with ignoreDifferences:

```yaml
# No automated block — requires human approval
syncPolicy:
  syncOptions:
    - CreateNamespace=true
    - ServerSideApply=true
    - ApplyOutOfSyncOnly=true
  retry:
    limit: 3
    backoff:
      duration: 10s
      factor: 2
      maxDuration: 5m

ignoreDifferences:
  - group: apps
    kind: Deployment
    jsonPointers:
      - /spec/replicas   # HPA manages replica count — don't revert it
```

The `ignoreDifferences` on `/spec/replicas` is critical in prod: HPA may scale the deployment up from 3 to 7 based on load. Without this, Argo CD would report the app as OutOfSync and a sync would revert it to 3.

### Sync Policies & Sync Windows

Argo CD Sync Windows block or allow syncs on a time-based schedule. The prod ApplicationSet defines a DENY window covering NYSE trading hours:

```
NYSE Market Hours: Monday–Friday 09:30–16:00 ET
UTC equivalent:   Monday–Friday 14:30–21:00 UTC

Cron: 30 14 * * 1-5  (start)
Duration: 6h30m
```

During this window, even if a human clicks "Sync" in the Argo CD UI, the sync is blocked. Only users with the `cluster-admin` role can override a sync window using the `--force` flag.

This mirrors real financial infrastructure where change freezes are enforced during market hours to protect order routing stability.

---

## 6. Phase 3 — AWS VPC Lattice

### Why Not VPC Peering

VPC Peering has several limitations that make it unsuitable for large-scale financial infrastructure:

| Problem | Impact |
|---|---|
| Non-transitive routing | A→B and B→C peering does NOT allow A→C |
| CIDR conflicts | Peered VPCs cannot have overlapping IP ranges |
| Route table sprawl | Every subnet needs explicit routes to every peer |
| No service-level policy | You're exposing entire VPCs, not individual services |
| No L7 visibility | Operates at L3 — no HTTP routing, no path-based rules |

**AWS VPC Lattice** solves all of these. It is a managed application networking service that operates at Layer 7 within the AWS network fabric — no VPC peering, no Transit Gateway, no sidecar proxies required.

### Lattice Components

All resources are defined in `terraform/modules/lattice/main.tf`:

```
aws_vpclattice_service_network "nasdaq-service-network"
│
│  Associates both VPCs to the same service network
├── aws_vpclattice_service_network_vpc_association (dev VPC)
├── aws_vpclattice_service_network_vpc_association (prod VPC)
│
│  Registers logical services into the network
├── aws_vpclattice_service "market-data-service"
│   ├── aws_vpclattice_service_network_service_association
│   ├── aws_vpclattice_target_group "market-data-dev"  (IP type, port 8080)
│   ├── aws_vpclattice_target_group "market-data-prod" (IP type, port 8080)
│   ├── aws_vpclattice_listener "market-data-http" (HTTP:80)
│   └── aws_vpclattice_listener_rule "market-data-api-v1"
│       └── Path match: /api/v1/market-data/* → market-data-prod target group
│
└── aws_vpclattice_service "order-execution-api"
    ├── aws_vpclattice_service_network_service_association
    ├── aws_vpclattice_target_group "order-execution-dev"
    ├── aws_vpclattice_target_group "order-execution-prod"
    └── aws_vpclattice_listener "order-execution-http" (HTTP:80)
```

### Layer 7 Routing

Target groups are of type `IP`, meaning Lattice sends traffic directly to pod IP addresses. Health checks hit `/health` on port 8080 and require HTTP 200.

The path-based routing rule:
```hcl
match {
  http_match {
    path_match {
      match {
        prefix = "/api/v1/market-data/"
      }
      case_sensitive = false
    }
  }
}

action {
  forward {
    target_groups {
      target_group_identifier = aws_vpclattice_target_group.market_data_prod.id
      weight                  = 100
    }
  }
}
```

The Order Execution API calls market data via the Lattice-assigned DNS name (set automatically in `values/values-prod.yaml` by `setup-lattice.sh`):

```
GET http://<lattice-market-data-dns>/api/v1/market-data/AAPL
```

This request travels through Lattice. The dev and prod VPCs never exchange routing table entries, security group rules, or peering connections.

---

## 7. Phase 4 — Observability, Drift & Rollbacks

### Drift Detection & Self-Heal

Argo CD continuously compares the live cluster state against the Git repository. The reconciliation loop runs every 3 minutes by default (configurable via `timeout.reconciliation`).

When a manual `kubectl` change is made to a resource managed by Argo CD, the app transitions to `OutOfSync` status. With `selfHeal: true` on the dev ApplicationSet, Argo CD will automatically re-apply the Git state without human intervention.

**Demo:**

```bash
./scripts/simulate-drift.sh
```

This script:
1. Scales the `order-execution-api` Deployment to 5 replicas out-of-band
2. Prints the current replica count
3. Watches with `kubectl get deployment -w`
4. Within ~3 minutes, Argo CD detects the drift and scales back to the Git-defined value (1 for dev)

In the Argo CD UI you will see the application transition:
```
Synced → OutOfSync → Syncing → Synced
```

### Canary Rollouts

Argo Rollouts replaces the standard Kubernetes `Deployment` for the Order Execution API in prod. It implements a canary strategy where traffic is incrementally shifted to the new version while metrics are continuously evaluated.

The 8-step canary in `gitops/rollouts/order-execution-api-rollout.yaml`:

```
Step 1:  setWeight: 10      → 10% of traffic goes to canary
Step 2:  pause: 60s         → observe metrics for 1 minute
Step 3:  setWeight: 30      → promote to 30% traffic
Step 4:  pause: 60s         → observe metrics for 1 minute
Step 5:  analysis           → run AnalysisTemplate (Prometheus queries)
Step 6:  setWeight: 60      → promote to 60% traffic (if analysis passes)
Step 7:  pause: 60s         → final observation window
Step 8:  setWeight: 100     → full promotion to new version
```

Traffic splitting is implemented by maintaining two Kubernetes Services:
- `order-execution-api-stable` — points to stable pods (selector includes stable hash)
- `order-execution-api-canary` — points to canary pods

Argo Rollouts modifies the pod selector labels on these Services as it progresses through steps.

### Analysis Templates

The `AnalysisTemplate` in `gitops/rollouts/analysis-template.yaml` evaluates three Prometheus metrics every 30 seconds during the analysis step:

| Metric | Query | Pass Condition | Fail Limit |
|---|---|---|---|
| Error Rate | `rate(5xx) / rate(all)` | `< 0.05` (under 5%) | 3 consecutive failures |
| P99 Latency | `histogram_quantile(0.99, ...)` | `< 0.5` (under 500ms) | 3 consecutive failures |
| Success Rate | `rate(2xx) / rate(all)` | `> 0.95` (over 95%) | 3 consecutive failures |

If any metric fails 3 consecutive evaluations, the AnalysisRun transitions to `Failed`, and the Rollout automatically executes a rollback — reverting to the last stable Git SHA with zero human intervention.

**Demo:**

```bash
./scripts/canary-test.sh
```

This deploys the image with `APP_ENV=broken` which causes all `GET /api/v1/orders` and `POST /api/v1/orders` requests to return HTTP 500. The error rate metric will breach the 5% threshold within 60–90 seconds, triggering automatic rollback.

---

## 8. The Services

### Order Execution API

**Source:** `services/order-execution-api/main.py`
**Framework:** FastAPI + Uvicorn
**Port:** 8080

| Endpoint | Method | Description |
|---|---|---|
| `/health` | GET | Liveness/readiness probe. Returns version, env, pod name |
| `/api/v1/orders` | GET | List all orders (returns 500 in `broken` mode) |
| `/api/v1/orders` | POST | Create order; fetches live market data from Market Data Service |
| `/api/v1/orders/{order_id}` | GET | Get a single order by ID |
| `/api/v1/orders/{order_id}` | DELETE | Cancel a PENDING order |
| `/metrics` | GET | Prometheus metrics (auto-instrumented) |

**Order creation logic:**
1. Accepts `{ symbol, quantity, price, side }`
2. Calls `MARKET_DATA_URL/{symbol}` via httpx (async, 5s timeout)
3. If market price is fetched and the submitted price is within 2% of market, order is `FILLED` immediately
4. If market data is unavailable, 80% random fill simulation (graceful degradation)
5. Returns the created order with a UUID-based `order_id`

**Broken mode** (for canary testing): Set `APP_ENV=broken` via Helm values or directly. All order endpoints return HTTP 500. The health endpoint always returns 200 so the pod stays Running — this isolates the canary failure to application-layer metrics.

**Environment variables:**

| Variable | Default | Description |
|---|---|---|
| `APP_VERSION` | `1.0.0` | Included in `/health` response |
| `APP_ENV` | `default` | Set to `broken` to simulate failure |
| `MARKET_DATA_URL` | `http://market-data-service/...` | Overridden per environment by Helm values |
| `LOG_LEVEL` | `info` | `debug` in dev, `warn` in prod |
| `POD_NAME` | `unknown` | Injected via Downward API in Helm chart |
| `POD_NAMESPACE` | `unknown` | Injected via Downward API in Helm chart |

**Observability:** All log entries are structured JSON via `python-json-logger`. Prometheus metrics are auto-instrumented by `prometheus-fastapi-instrumentator`, which exposes `http_requests_total` (labeled by method, path, status) and `http_request_duration_seconds` histogram — the exact metrics the AnalysisTemplate queries.

### Market Data Service

**Source:** `services/market-data-service/main.py`
**Framework:** FastAPI + Uvicorn
**Port:** 8080

| Endpoint | Method | Description |
|---|---|---|
| `/health` | GET | Liveness/readiness probe |
| `/api/v1/market-data` | GET | Returns quotes for all 8 tracked symbols |
| `/api/v1/market-data/{symbol}` | GET | Returns quote for a specific symbol |
| `/metrics` | GET | Prometheus metrics |

**Tracked symbols:** AAPL, GOOGL, MSFT, AMZN, TSLA, NVDA, META, NFLX

Each quote response includes realistic spread simulation:

```json
{
  "symbol": "AAPL",
  "bid": 182.47,
  "ask": 182.53,
  "last_price": 182.50,
  "volume": 47291038,
  "change_pct": 0.42,
  "timestamp": "2026-05-18T14:32:01Z"
}
```

---

## 9. Helm Charts

### Chart Structure

Both services use the same chart structure pattern. The `order-execution-api` chart is more complete (includes HPA, ServiceAccount with IRSA support).

### Environment Overrides

Values are layered: `values.yaml` provides defaults, and per-environment files override:

```
values.yaml          ← loaded always
values-dev.yaml      ← merged on top for dev deployments
values-prod.yaml     ← merged on top for prod deployments
```

| Setting | Dev | Prod |
|---|---|---|
| `replicaCount` | 1 | 3 |
| `resources.requests.cpu` | 100m | 250m |
| `resources.limits.cpu` | 300m | 1000m |
| `resources.requests.memory` | 128Mi | 256Mi |
| `resources.limits.memory` | 256Mi | 512Mi |
| `env.LOG_LEVEL` | debug | warn |
| `env.APP_ENV` | development | production |
| `autoscaling.enabled` | false | true |
| `autoscaling.minReplicas` | — | 3 |
| `autoscaling.maxReplicas` | — | 10 |
| `autoscaling.targetCPU` | — | 70% |

### HPA Behavior (prod only)

The HPA uses `autoscaling/v2` with configured scale-up and scale-down behavior:

```yaml
behavior:
  scaleUp:
    stabilizationWindowSeconds: 60
    policies:
    - type: Pods
      value: 2
      periodSeconds: 60
  scaleDown:
    stabilizationWindowSeconds: 300
    policies:
    - type: Pods
      value: 1
      periodSeconds: 120
```

Scale-up is aggressive (add up to 2 pods per minute) to handle market open surges. Scale-down is conservative (remove 1 pod every 2 minutes, with a 5-minute stabilization window) to avoid flapping.

### IRSA ServiceAccount

The ServiceAccount template supports IRSA annotations for AWS API access:

```yaml
annotations:
  eks.amazonaws.com/role-arn: arn:aws:iam::ACCOUNT_ID:role/order-execution-api-role
```

This is set in `values-prod.yaml` using `serviceAccount.annotations`.

---

## 10. Monitoring Stack

Installed on all clusters via `monitoring/install-monitoring.sh` using the `kube-prometheus-stack` Helm chart.

**Grafana credentials:** `admin` / `nasdaq123`

**Components deployed:**

| Component | Purpose |
|---|---|
| Prometheus | Scrapes `/metrics` from both services every 15s |
| Grafana | Dashboards: Kubernetes cluster overview (ID 315), NGINX (ID 9614), custom service dashboards |
| kube-state-metrics | Exposes Kubernetes object metrics (pod restarts, deployment status) |
| node-exporter | Host-level metrics (CPU, memory, disk) |

**Prometheus scrape config targets both service namespaces:**

```yaml
additionalScrapeConfigs:
  - job_name: 'order-execution-api'
    kubernetes_sd_configs:
      - role: pod
        namespaces:
          names: [order-api]
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_label_app]
        regex: order-execution-api
        action: keep
```

**Useful Prometheus queries:**

```promql
# Request rate (rps)
rate(http_requests_total{app="order-execution-api"}[2m])

# Error rate
sum(rate(http_requests_total{app="order-execution-api",status=~"5.."}[2m]))
/
sum(rate(http_requests_total{app="order-execution-api"}[2m]))

# P99 latency
histogram_quantile(0.99,
  sum(rate(http_request_duration_seconds_bucket{app="order-execution-api"}[5m])) by (le)
)

# Argo Rollout canary weight
argo_rollout_info{namespace="order-api"}
```

---

## 11. Prerequisites & Setup

### Required Tools

| Tool | Minimum Version | Install |
|---|---|---|
| AWS CLI | 2.x | https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html |
| Terraform | 1.7.0 | https://developer.hashicorp.com/terraform/downloads |
| kubectl | 1.29 | https://kubernetes.io/docs/tasks/tools/ |
| Helm | 3.14 | https://helm.sh/docs/intro/install/ |
| Argo CD CLI | 2.10 | https://argo-cd.readthedocs.io/en/stable/cli_installation/ |
| Argo Rollouts kubectl plugin | 1.7 | `kubectl argo rollouts version` |
| envsubst | (GNU gettext) | Usually pre-installed on Linux/macOS |

**Verify all tools:**

```bash
aws --version
terraform version
kubectl version --client
helm version
argocd version --client
kubectl argo rollouts version
```

### AWS Permissions

Your AWS IAM principal needs these permissions:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["eks:*"], "Resource": "*" },
    { "Effect": "Allow", "Action": ["ec2:*"], "Resource": "*" },
    { "Effect": "Allow", "Action": ["iam:*"], "Resource": "*" },
    { "Effect": "Allow", "Action": ["s3:*"], "Resource": "*" },
    { "Effect": "Allow", "Action": ["dynamodb:*"], "Resource": "*" },
    { "Effect": "Allow", "Action": ["vpc-lattice:*"], "Resource": "*" },
    { "Effect": "Allow", "Action": ["elasticloadbalancing:*"], "Resource": "*" }
  ]
}
```

For a production account, scope these to specific resource ARNs.

### AWS CLI Configuration

```bash
aws configure
# AWS Access Key ID: <your key>
# AWS Secret Access Key: <your secret>
# Default region name: us-east-1
# Default output format: json
```

---

## 12. Deployment Guide

### Step 1: Clone and Configure

```bash
git clone https://github.com/secant78/multi-cluster-gitops.git
cd multi-cluster-gitops
```

Update the `repoURL` in the ApplicationSets to point to your fork:

```bash
# In gitops/argocd/applicationsets/order-execution-api-appset.yaml
# Change: repoURL: https://github.com/YOUR_ORG/mini-nasdaq-gitops.git
# To:     repoURL: https://github.com/secant78/multi-cluster-gitops.git
```

### Step 2: Bootstrap Terraform State

```bash
cd terraform/bootstrap
terraform init
terraform apply -auto-approve
cd ../..
```

### Step 3: Provision All Clusters

```bash
# Management cluster
cd terraform/environments/mgmt
terraform init && terraform apply -auto-approve
cd ../../..

# Dev cluster
cd terraform/environments/dev
terraform init && terraform apply -auto-approve
cd ../../..

# Prod cluster
cd terraform/environments/prod
terraform init && terraform apply -auto-approve
cd ../../..
```

Each cluster takes approximately 15–20 minutes to provision.

**Or run the all-in-one bootstrap script:**

```bash
chmod +x scripts/bootstrap.sh
./scripts/bootstrap.sh
```

### Step 4: Configure kubeconfig

```bash
aws eks update-kubeconfig --region us-east-1 --name eks-mgmt --alias eks-mgmt
aws eks update-kubeconfig --region us-east-1 --name eks-dev  --alias eks-dev
aws eks update-kubeconfig --region us-east-1 --name eks-prod --alias eks-prod

kubectl config get-contexts
```

### Step 5: Install Argo CD HA

```bash
kubectl config use-context eks-mgmt

helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --values gitops/argocd/install/argocd-ha-values.yaml \
  --wait --timeout 10m
```

### Step 6: Access Argo CD

```bash
# Get the admin password
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)

echo "ArgoCD Password: $ARGOCD_PASSWORD"

# Get the LoadBalancer URL
ARGOCD_URL=$(kubectl -n argocd get svc argocd-server \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo "ArgoCD URL: http://$ARGOCD_URL"

# Login via CLI
argocd login $ARGOCD_URL \
  --username admin \
  --password $ARGOCD_PASSWORD \
  --insecure
```

### Step 7: Register Spoke Clusters

```bash
chmod +x gitops/argocd/clusters/register-clusters.sh
./gitops/argocd/clusters/register-clusters.sh

# Verify
argocd cluster list
```

### Step 8: Install Argo Rollouts on Spoke Clusters

```bash
for ctx in eks-dev eks-prod; do
  kubectl config use-context $ctx
  kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -n argo-rollouts \
    -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
done
```

### Step 9: Apply ApplicationSets

```bash
kubectl config use-context eks-mgmt

kubectl apply -f gitops/argocd/applicationsets/order-execution-api-appset.yaml

# Watch sync progress
watch argocd app list
```

### Step 10: Install Monitoring

```bash
chmod +x monitoring/install-monitoring.sh

# Install on dev
./monitoring/install-monitoring.sh eks-dev

# Install on prod
./monitoring/install-monitoring.sh eks-prod
```

### Step 11: Provision VPC Lattice

```bash
chmod +x scripts/setup-lattice.sh
./scripts/setup-lattice.sh
```

### Step 12: Apply Rollout Resources (prod)

```bash
kubectl config use-context eks-prod

kubectl apply -f gitops/rollouts/rollout-services.yaml
kubectl apply -f gitops/rollouts/analysis-template.yaml
kubectl apply -f gitops/rollouts/order-execution-api-rollout.yaml

kubectl argo rollouts get rollout order-execution-api -n order-api
```

---

## 13. Demo Playbook

### Demo 1: Observe GitOps in Action (Dev)

```bash
# Watch live application status
watch argocd app get order-execution-api-dev

# Make a change to values-dev.yaml (e.g. add an env var)
# Commit and push — Argo CD will auto-apply within 3 minutes
```

### Demo 2: Drift Remediation

```bash
# Run the drift simulation
./scripts/simulate-drift.sh

# In another terminal, watch the Argo CD UI or:
watch kubectl get deployment order-execution-api -n order-api --context eks-dev

# Expected: replicas goes 1 → 5 (drift) → 1 (self-healed)
```

### Demo 3: Canary Auto-Rollback

```bash
# Deploy broken version to prod
./scripts/canary-test.sh

# In another terminal, stream rollout status:
kubectl argo rollouts get rollout order-execution-api \
  -n order-api \
  --context eks-prod \
  --watch

# Expected timeline:
# 0:00  Canary step 1 — 10% traffic to broken image
# 0:60  Canary pauses — Prometheus queries begin
# 1:30  Analysis FAILED (error rate > 5%)
# 1:31  Rollout begins automatic rollback
# 2:00  100% traffic back on stable image
```

### Demo 4: Prod Sync Window (Market Hours Block)

```bash
# Switch to prod cluster and check sync windows
kubectl config use-context eks-mgmt
argocd app get order-execution-api-prod

# During NYSE hours (Mon-Fri 09:30-16:00 ET) you will see:
# SYNC STATUS: OutOfSync
# MESSAGE: Cannot sync during active sync window

# Try to sync manually — it will be blocked:
argocd app sync order-execution-api-prod
# ERROR: Blocked by sync window
```

### Demo 5: VPC Lattice Cross-VPC Call

```bash
# Exec into an order-api pod in prod
kubectl config use-context eks-prod
POD=$(kubectl get pod -n order-api -l app=order-execution-api -o jsonpath='{.items[0].metadata.name}')

kubectl exec -it $POD -n order-api -- \
  curl http://<LATTICE_MARKET_DATA_DNS>/api/v1/market-data/AAPL

# Expected: real-time quote from market-data-service running in eks-dev
# No VPC peering. No sidecar. Just Lattice.
```

---

## 14. Cost Estimate

All resources are in `us-east-1`. Estimates based on on-demand pricing as of 2026.

| Resource | Count | Unit Cost | Monthly |
|---|---|---|---|
| EKS Cluster Control Plane | 3 | $0.10/hr | ~$216 |
| EC2 t3.medium (nodes) | 6 (2 per cluster) | $0.0416/hr | ~$180 |
| NAT Gateway (hourly) | 6 (2 per cluster) | $0.045/hr | ~$195 |
| NAT Gateway (data processed) | ~100GB | $0.045/GB | ~$5 |
| Elastic IPs | 6 | $0.005/hr | ~$22 |
| S3 (state bucket, minimal) | 1 | negligible | ~$1 |
| DynamoDB (PAY_PER_REQUEST) | 1 | negligible | ~$1 |
| VPC Lattice (service network) | 1 | $0.025/hr | ~$18 |
| VPC Lattice (requests) | demo usage | $0.0025/1K req | ~$5 |
| **Total (running 24/7)** | | | **~$643/month** |

**To minimize costs:**

```bash
# Scale node groups to 0 when not in use:
aws eks update-nodegroup-config \
  --cluster-name eks-dev \
  --nodegroup-name eks-dev-nodes \
  --scaling-config minSize=0,maxSize=3,desiredSize=0

# Or destroy environments when done:
cd terraform/environments/dev && terraform destroy -auto-approve
```

---

## 15. Cleanup

Destroy in reverse order to avoid dependency conflicts:

```bash
# 1. Remove Lattice (no cluster dependencies)
cd terraform/environments/lattice
terraform destroy -auto-approve
cd ../..

# 2. Remove spoke clusters
cd terraform/environments/prod
terraform destroy -auto-approve
cd ../..

cd terraform/environments/dev
terraform destroy -auto-approve
cd ../..

# 3. Remove management cluster (Argo CD runs here)
cd terraform/environments/mgmt
terraform destroy -auto-approve
cd ../..

# 4. (Optional) Remove state backend — only if truly done
cd terraform/bootstrap
terraform destroy -auto-approve
```

> **Warning:** Destroying the state backend (`terraform/bootstrap`) deletes the S3 bucket and DynamoDB table. This is irreversible and will require re-bootstrapping before any future `terraform apply`.

---

## 16. Troubleshooting

### Argo CD App Stuck in `Progressing`

```bash
# Get detailed app status
argocd app get order-execution-api-dev --refresh

# Check pod events
kubectl describe pod -n order-api -l app=order-execution-api --context eks-dev

# Check rollout if using Argo Rollouts
kubectl argo rollouts describe order-execution-api -n order-api --context eks-prod
```

### Cluster Not Registered in Argo CD

```bash
# List registered clusters
argocd cluster list

# List secrets in argocd namespace
kubectl get secret -n argocd -l argocd.argoproj.io/secret-type=cluster

# Re-run registration
argocd cluster add eks-dev --label env=dev --upsert
```

### VPC Lattice DNS Not Resolving

1. Confirm VPC associations are `ACTIVE`:
   ```bash
   aws vpc-lattice list-service-network-vpc-associations \
     --service-network-identifier nasdaq-service-network
   ```
2. Ensure worker node security groups allow inbound from Lattice prefix list `pl-XXXX`
3. Verify target group health — unhealthy targets won't receive requests:
   ```bash
   aws vpc-lattice list-targets \
     --target-group-identifier <target-group-id>
   ```

### Terraform State Lock Stuck

```bash
# Get the lock ID from the error message, then:
terraform force-unlock <LOCK_ID>

# If the lock is stale (e.g. a previous apply was killed):
aws dynamodb delete-item \
  --table-name nasdaq-gitops-tf-locks \
  --key '{"LockID": {"S": "nasdaq-gitops-tfstate/mgmt/terraform.tfstate"}}'
```

### Rollout Analysis Failing Immediately (No Metrics)

Prometheus may not have data if the services have received zero traffic. Generate some:

```bash
# Port-forward and send test traffic
kubectl port-forward svc/order-execution-api-stable 8080:80 -n order-api --context eks-prod &

for i in $(seq 1 50); do
  curl -s http://localhost:8080/api/v1/orders > /dev/null
done
```

### HPA Not Scaling

```bash
kubectl describe hpa order-execution-api -n order-api --context eks-prod

# Common cause: metrics-server not installed
kubectl top pods -n order-api
# If this fails, install metrics-server:
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

### EKS Node Group Stuck in `Degraded`

```bash
# Check node group status
aws eks describe-nodegroup \
  --cluster-name eks-dev \
  --nodegroup-name eks-dev-nodes \
  --query 'nodegroup.health'

# Common cause: IAM role missing policy
aws iam list-attached-role-policies \
  --role-name eks-dev-node-group-role
```

---

## 17. Key Design Decisions

**Two ApplicationSets instead of one with a cluster generator**
A single `ApplicationSet` with a cluster generator produces identical `syncPolicy` blocks for all matching clusters. Since dev needs automated sync and prod needs a manual gate, splitting into two separate ApplicationSets was cleaner and more explicit than embedding conditional logic in a Go template.

**`ignoreDifferences` on `/spec/replicas` in prod**
The prod HPA actively manages replica counts. Without this, every HPA scaling event would cause Argo CD to report `OutOfSync` and a manual sync would revert HPA's work back to the Git-defined `replicaCount: 3`. This is a common production pitfall with GitOps + HPA.

**Separate Terraform state files per environment**
Sharing a single state file across all three clusters creates blast radius risk: a bad `terraform apply` could affect all environments simultaneously. Isolated state files mean environment changes are independent. The tradeoff is managing four `terraform init` operations, which `bootstrap.sh` handles.

**VPC Lattice instead of Istio for cross-VPC communication**
Istio multi-cluster requires either flat networking (pod IPs routable across clusters) or complex gateway configurations. For genuinely isolated VPCs, it adds significant operational overhead (certificate management, mTLS, control plane federation). VPC Lattice provides L7 routing natively in AWS without any in-cluster agent — the network fabric handles it.

**`APP_ENV=broken` as the canary failure mechanism**
Rather than building a separate "broken" Docker image, the same image supports a runtime failure mode via environment variable. This means only the Helm values need to change to trigger a canary failure test — no registry push required. The health endpoint still returns 200 so Kubernetes doesn't restart the pod; the failure is observable only at the application metrics layer.

**`ServerSideApply=true` in sync options**
Server-Side Apply (SSA) replaces the older client-side apply approach. With SSA, field managers are tracked server-side, preventing `last-applied-configuration` annotation conflicts when multiple controllers (HPA, Argo CD, Argo Rollouts) touch the same resource.

---

## 18. Glossary

| Term | Definition |
|---|---|
| **ApplicationSet** | An Argo CD CRD that generates multiple `Application` objects from a single template using generators (cluster, git, list, matrix) |
| **IRSA** | IAM Roles for Service Accounts — binds an AWS IAM role to a Kubernetes ServiceAccount via OIDC federation |
| **OIDC** | OpenID Connect — federated identity protocol used by EKS to allow pods to assume IAM roles without long-lived credentials |
| **Sync Window** | Argo CD schedule that blocks or allows syncs during specified time ranges |
| **Self-Heal** | Argo CD behavior where detected drift (live state ≠ Git state) is automatically corrected |
| **VPC Lattice** | AWS managed application networking service providing L7 service-to-service connectivity without VPC peering |
| **Canary Deployment** | Progressive traffic shift where a new version receives a small % of traffic first, with automatic rollback on failure |
| **AnalysisTemplate** | Argo Rollouts CRD that defines success/failure criteria for a canary deployment using metrics providers |
| **Consistent Hashing** | Argo CD Application Controller sharding algorithm that distributes Application ownership across controller replicas |
| **Redis HA** | High-availability Redis deployment with Sentinel for automatic primary failover |
| **Target Group** | VPC Lattice resource that groups backend instances (pods by IP) for a logical service |
| **HPA** | Horizontal Pod Autoscaler — Kubernetes controller that adjusts replica counts based on CPU/memory/custom metrics |
| **SSA** | Server-Side Apply — Kubernetes apply strategy that tracks field ownership server-side to prevent annotation conflicts |
| **Drift** | Any difference between the live cluster state and what is declared in the Git repository |
