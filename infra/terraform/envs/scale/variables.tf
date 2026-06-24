# scale tier — the benchmark box. Same stack module as dev; only these
# values differ (ADR-0005): a 4-GPU node, NO third-party egress, private API.
# Benchmark tier in us-west-2: full G+P quotas (us-east-1 is capacity-starved
# for big GPU boxes; us-east-2 has zero G quota). Region is just a value.
variable "region" {
  type    = string
  default = "us-west-2"
}

variable "aws_profile" {
  type    = string
  default = "kelsus-dev"
}

variable "env" {
  type    = string
  default = "scale"
}

variable "cluster_name" {
  type    = string
  default = "kelsus-refarch-scale"
}

variable "cluster_version" {
  type    = string
  default = "1.31"
}

variable "vpc_cidr" {
  type    = string
  default = "10.43.0.0/16"
}

variable "az_count" {
  type    = number
  default = 2
}

# GPU capacity: Karpenter. At scale-tier bring-up, apply a NodePool for
# g6e.12xlarge (4x L40S, TP=4) / p5 H100 spot — see infra/helm/
# karpenter-nodepool.yaml as the template. No node-group variables.

variable "system_instance_type" {
  type    = string
  default = "m6i.large"
}

# Benchmark-run posture: NAT + public API for pragmatic bring-up (HF model
# pulls, public registries, laptop kubectl). The sovereign no-egress posture
# (nat=false, public=false -> VPC endpoints only) remains a config flip and is
# exercised as part of pre-publish validation.
variable "enable_nat_gateway" {
  type    = bool
  default = true
}

variable "cluster_endpoint_public_access" {
  type    = bool
  default = true
}

variable "gpu_extra_az_count" {
  description = "us-west-2 has 4 AZs total; core 2 + 2 extra covers them all."
  type        = number
  default     = 2
}
