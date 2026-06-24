terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }

  # Sprint 0 uses local state. Before any shared/CI use, switch to a remote
  # backend (create the bucket + table once, out of band):
  #
  # backend "s3" {
  #   bucket         = "kelsus-refarch-tfstate"
  #   key            = "envs/dev/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "kelsus-refarch-tflock"
  #   encrypt        = true
  # }
}
