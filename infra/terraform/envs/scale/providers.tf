provider "aws" {
  region  = var.region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project   = "kelsus-oss-ai-ref-arch"
      Env       = var.env
      ManagedBy = "terraform"
      Owner     = "kelsus-capabilities"
    }
  }
}
