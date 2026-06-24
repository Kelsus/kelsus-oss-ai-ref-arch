# dev tier — cheap iteration. One small GPU, NAT on, public API endpoint.
# Differs from envs/scale ONLY in the values passed here (ADR-0005).
module "stack" {
  source = "../../modules/refarch-stack"

  env             = var.env
  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version
  vpc_cidr        = var.vpc_cidr
  az_count        = var.az_count

  system_instance_type = var.system_instance_type

  enable_nat_gateway             = var.enable_nat_gateway
  cluster_endpoint_public_access = var.cluster_endpoint_public_access
}
