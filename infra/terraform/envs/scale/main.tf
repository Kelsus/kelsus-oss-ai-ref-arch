# scale tier — identical stack module to dev, different values only.
module "stack" {
  source = "../../modules/refarch-stack"

  env                = var.env
  cluster_name       = var.cluster_name
  cluster_version    = var.cluster_version
  vpc_cidr           = var.vpc_cidr
  az_count           = var.az_count
  gpu_extra_az_count = var.gpu_extra_az_count

  system_instance_type = var.system_instance_type

  enable_nat_gateway             = var.enable_nat_gateway
  cluster_endpoint_public_access = var.cluster_endpoint_public_access
}
