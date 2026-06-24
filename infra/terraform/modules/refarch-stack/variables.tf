variable "env" {
  description = "Environment name (dev | scale | prod)."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
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
  description = "Number of AZs to spread across."
  type        = number
  default     = 2
}

# GPU capacity is defined by Karpenter (infra/helm/karpenter-nodepool.yaml),
# not by node-group variables — instance type, disk, and fleet limits live in
# the NodePool/EC2NodeClass spec.

variable "gpu_extra_az_count" {
  description = "Extra AZs (beyond az_count) given Karpenter-discoverable subnets for GPU capacity-hunting. Big GPU instances ICE often; more AZs = more capacity pools."
  type        = number
  default     = 4 # a-f: p5 (H100) is offered in us-east-1e/1f, which the core 4 AZs miss
}

variable "system_instance_type" {
  type    = string
  default = "m6i.large"
}

variable "enable_nat_gateway" {
  description = "dev=true (convenience); scale/prod=false (VPC-endpoint-only, no third-party egress)."
  type        = bool
}

variable "cluster_endpoint_public_access" {
  description = "dev=true (kubectl from laptop); scale/prod=false (private endpoint only)."
  type        = bool
}

variable "enable_flow_logs" {
  description = "Capture VPC flow logs to CloudWatch (SOC2 CC7). On by default; flip off for cost-sensitive throwaway clusters."
  type        = bool
  default     = true
}
