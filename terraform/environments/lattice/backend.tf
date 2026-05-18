terraform {
  backend "s3" {
    bucket         = "nasdaq-gitops-tfstate"
    key            = "lattice/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "nasdaq-gitops-tf-locks"
  }
}
