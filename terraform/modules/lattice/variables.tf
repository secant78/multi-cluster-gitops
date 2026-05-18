variable "dev_vpc_id" {
  description = "VPC ID of the dev EKS cluster"
  type        = string
}

variable "prod_vpc_id" {
  description = "VPC ID of the prod EKS cluster"
  type        = string
}

variable "dev_subnet_ids" {
  description = "Subnet IDs in the dev VPC for Lattice target groups"
  type        = list(string)
}

variable "prod_subnet_ids" {
  description = "Subnet IDs in the prod VPC for Lattice target groups"
  type        = list(string)
}

variable "tags" {
  description = "Map of tags to apply to all resources"
  type        = map(string)
  default     = {}
}
