provider "aws" {
  region = var.region

  default_tags {
    tags = {
      project = "eks-gitops"
      owner   = "matt-shaw"
    }
  }
}
