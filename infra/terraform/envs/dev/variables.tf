variable "region" {
  description = "AWS region (strategy's declared benchmark region)."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI/SSO profile to use."
  type        = string
  default     = "kelsus-dev"
}

variable "env" {
  description = "Environment name."
  type        = string
  default     = "dev"
}

variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
  default     = "kelsus-refarch-dev"
}

variable "cluster_version" {
  description = "EKS Kubernetes version."
  type        = string
  default     = "1.31"
}

variable "vpc_cidr" {
  description = "CIDR for the reference VPC."
  type        = string
  default     = "10.42.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones to spread across."
  type        = number
  default     = 2
}

# GPU capacity: Karpenter NodePool (infra/helm/karpenter-nodepool.yaml) — no
# node-group variables. On/off = scale deploy/vllm (make gpu-pause / gpu-resume).

# --- System node group (CPU: coredns, gateway, observability) ---------------
variable "system_instance_type" {
  description = "Instance type for the CPU/system node group."
  type        = string
  default     = "m6i.large"
}

# --- Sovereign networking toggles ([ADR-0001]) ------------------------------
variable "enable_nat_gateway" {
  description = "dev=true for convenience; scale/prod=false (VPC-endpoint-only, no third-party egress)."
  type        = bool
  default     = true
}

variable "cluster_endpoint_public_access" {
  description = "dev=true so you can kubectl from your laptop; scale/prod=false (private endpoint only)."
  type        = bool
  default     = true
}
