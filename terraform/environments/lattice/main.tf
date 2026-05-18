locals {
  common_tags = {
    Project     = "mini-nasdaq-gitops"
    Component   = "lattice"
    ManagedBy   = "terraform"
  }
}

# Data sources to look up dev and prod EKS VPCs
data "aws_eks_cluster" "dev" {
  name = "eks-dev"
}

data "aws_eks_cluster" "prod" {
  name = "eks-prod"
}

# Extract VPC IDs from EKS cluster resource VPC config
data "aws_vpc" "dev" {
  id = data.aws_eks_cluster.dev.vpc_config[0].vpc_id
}

data "aws_vpc" "prod" {
  id = data.aws_eks_cluster.prod.vpc_config[0].vpc_id
}

# Look up private subnets in dev and prod VPCs
data "aws_subnets" "dev_private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.dev.id]
  }

  filter {
    name   = "tag:kubernetes.io/role/internal-elb"
    values = ["1"]
  }
}

data "aws_subnets" "prod_private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.prod.id]
  }

  filter {
    name   = "tag:kubernetes.io/role/internal-elb"
    values = ["1"]
  }
}

module "lattice" {
  source = "../../modules/lattice"

  dev_vpc_id      = data.aws_vpc.dev.id
  prod_vpc_id     = data.aws_vpc.prod.id
  dev_subnet_ids  = data.aws_subnets.dev_private.ids
  prod_subnet_ids = data.aws_subnets.prod_private.ids

  tags = local.common_tags
}

output "service_network_arn" {
  value = module.lattice.service_network_arn
}

output "market_data_service_dns" {
  value = module.lattice.market_data_service_dns
}

output "order_execution_api_service_dns" {
  value = module.lattice.order_execution_api_service_dns
}
