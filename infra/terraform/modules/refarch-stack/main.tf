data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # Interface endpoints are only needed when there is no NAT egress.
  # In the sovereign posture (scale/prod), nodes reach AWS APIs exclusively
  # through these endpoints (ADR-0001).
  interface_endpoints = var.enable_nat_gateway ? {} : {
    ecr_api = { service = "ecr.api" }
    ecr_dkr = { service = "ecr.dkr" }
    logs    = { service = "logs" }
    sts     = { service = "sts" }
    ec2     = { service = "ec2" }
    eks     = { service = "eks" }
    # Reach Amazon Bedrock without internet egress (managed-model benchmark column).
    # Harmless when NAT is on — this whole map is empty in that posture.
    bedrock_runtime = { service = "bedrock-runtime" }
  }
}

# ---------------------------------------------------------------------------
# Network — audited community VPC module
# ---------------------------------------------------------------------------
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr
  azs  = local.azs

  private_subnets = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 48)]

  enable_nat_gateway   = var.enable_nat_gateway
  single_nat_gateway   = var.enable_nat_gateway
  enable_dns_hostnames = true
  enable_dns_support   = true

  # VPC flow logs -> CloudWatch (SOC2 CC7). The community module provisions the
  # log group + IAM role when these are set. Cluster-scoped: torn down with the
  # cluster, unlike the account-wide detective controls in envs/account-baseline.
  enable_flow_log                                 = var.enable_flow_logs
  create_flow_log_cloudwatch_iam_role             = var.enable_flow_logs
  create_flow_log_cloudwatch_log_group            = var.enable_flow_logs
  flow_log_cloudwatch_log_group_retention_in_days = 365
  flow_log_max_aggregation_interval               = 60

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    # Karpenter discovers subnets to launch nodes into by this tag.
    "karpenter.sh/discovery" = var.cluster_name
  }
  public_subnet_tags = { "kubernetes.io/role/elb" = 1 }
}

resource "aws_security_group" "vpce" {
  count       = var.enable_nat_gateway ? 0 : 1
  name        = "${var.cluster_name}-vpce"
  description = "Allow HTTPS from the VPC to interface endpoints"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }
}

module "vpc_endpoints" {
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "~> 5.13"

  vpc_id             = module.vpc.vpc_id
  security_group_ids = var.enable_nat_gateway ? [] : [aws_security_group.vpce[0].id]

  endpoints = merge(
    {
      s3 = {
        service         = "s3"
        service_type    = "Gateway"
        route_table_ids = module.vpc.private_route_table_ids
        tags            = { Name = "${var.cluster_name}-s3-gw" }
      }
    },
    {
      for k, v in local.interface_endpoints : k => {
        service             = v.service
        private_dns_enabled = true
        subnet_ids          = module.vpc.private_subnets
        tags                = { Name = "${var.cluster_name}-${k}" }
      }
    }
  )
}

# ---------------------------------------------------------------------------
# EKS — audited community module; our opinions are in the node groups
# ---------------------------------------------------------------------------
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.24"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access  = var.cluster_endpoint_public_access
  cluster_endpoint_private_access = true

  enable_cluster_creator_admin_permissions = true
  authentication_mode                      = "API_AND_CONFIG_MAP"

  cluster_addons = {
    coredns                = {}
    kube-proxy             = {}
    vpc-cni                = {}
    eks-pod-identity-agent = {}
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Karpenter discovers the node security group by this tag.
  node_security_group_tags = { "karpenter.sh/discovery" = var.cluster_name }

  eks_managed_node_groups = {
    # CPU node group: coredns, gateway, embeddings, observability, Karpenter
    # controller. GPU capacity is NOT a node group — Karpenter provisions GPU
    # nodes on pod demand and consolidates them away when empty (see
    # infra/helm/karpenter-nodepool.yaml).
    system = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = [var.system_instance_type]
      min_size       = 1
      max_size       = 3
      desired_size   = 2
    }
  }
}

# ---------------------------------------------------------------------------
# Model artifact bucket (ours) — weights live in-account, KMS-encrypted
# ---------------------------------------------------------------------------
module "model_bucket" {
  source = "../model-artifact-bucket"

  bucket_name = "kelsus-refarch-models-${var.env}-${data.aws_caller_identity.current.account_id}"
  kms_alias   = "alias/kelsus-refarch-models-${var.env}"
  env         = var.env
}

# ---------------------------------------------------------------------------
# Extra GPU-capacity subnets. Large GPU instances frequently ICE
# (InsufficientInstanceCapacity) in any given AZ; more AZs = more capacity
# pools for Karpenter to hunt. These subnets are tagged for Karpenter
# discovery only — NOT registered with the EKS cluster or node groups, so
# adding them causes zero churn to existing services. Worker nodes may live
# in any VPC subnet that routes to the cluster.
# ---------------------------------------------------------------------------
locals {
  gpu_extra_azs = slice(
    data.aws_availability_zones.available.names,
    var.az_count,
    min(var.az_count + var.gpu_extra_az_count, length(data.aws_availability_zones.available.names))
  )
}

resource "aws_subnet" "gpu_capacity" {
  for_each = { for i, az in local.gpu_extra_azs : az => i }

  vpc_id            = module.vpc.vpc_id
  availability_zone = each.key
  # /20s at offsets 4,5 — clear of the vpc module's private (0,1) and public
  # (/24s inside offset 3) allocations.
  cidr_block = cidrsubnet(var.vpc_cidr, 4, 4 + each.value)

  tags = {
    Name                     = "${var.cluster_name}-gpu-capacity-${each.key}"
    "karpenter.sh/discovery" = var.cluster_name
  }
}

resource "aws_route_table_association" "gpu_capacity" {
  for_each = aws_subnet.gpu_capacity

  subnet_id      = each.value.id
  route_table_id = module.vpc.private_route_table_ids[0]
}

# ---------------------------------------------------------------------------
# Karpenter — node provisioner. Replaces the static GPU node group: a Pending
# GPU pod causes a g6e node to be provisioned (~1 min); an empty node is
# consolidated away. This module creates the controller IAM (pod identity),
# the node IAM role, and the spot-interruption SQS queue. The controller is
# installed by infra/helm/karpenter-install.sh; NodePool/EC2NodeClass live in
# infra/helm/karpenter-nodepool.yaml.
# ---------------------------------------------------------------------------
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.24"

  cluster_name = module.eks.cluster_name

  enable_v1_permissions           = true
  enable_pod_identity             = true
  create_pod_identity_association = true
  namespace                       = "kube-system"

  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }
}

# ---------------------------------------------------------------------------
# Bench pod identity — lets in-cluster eval Jobs (SA "bench") read eval data
# from S3 and write results back, with no laptop credentials in the loop.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "bench_pod" {
  name = "${var.cluster_name}-bench-pod"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "bench_pod_s3" {
  name = "eval-bucket-access"
  role = aws_iam_role.bench_pod.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
        Resource = [module.model_bucket.bucket_arn, "${module.model_bucket.bucket_arn}/*"]
      },
      {
        # The bucket is CMK-encrypted; S3 access fails without the key.
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey*"]
        Resource = [module.model_bucket.kms_key_arn]
      }
    ]
  })
}

resource "aws_eks_pod_identity_association" "bench" {
  cluster_name    = module.eks.cluster_name
  namespace       = "default"
  service_account = "bench"
  role_arn        = aws_iam_role.bench_pod.arn
}

# ---------------------------------------------------------------------------
# Gateway pod identity — lets the in-cluster gateway (SA "gateway") call Amazon
# Bedrock for the managed-model benchmark column. Bedrock is reached via the
# bedrock-runtime interface endpoint (sovereign posture) or NAT (dev).
# ---------------------------------------------------------------------------
resource "aws_iam_role" "gateway_pod" {
  name = "${var.cluster_name}-gateway-pod"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "gateway_pod_bedrock" {
  name = "bedrock-invoke"
  role = aws_iam_role.gateway_pod.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      # Scoped to the action, not the model: the benchmark sweeps many model IDs
      # (and cross-region inference-profile ARNs). Tighten to specific ARNs if this
      # role is ever reused outside the benchmark.
      Effect   = "Allow"
      Action   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
      Resource = ["*"]
    }]
  })
}

resource "aws_eks_pod_identity_association" "gateway" {
  cluster_name    = module.eks.cluster_name
  namespace       = "default"
  service_account = "gateway"
  role_arn        = aws_iam_role.gateway_pod.arn
}

# NOTE: the GPU dead-man's switch is now in-cluster (infra/helm/
# gpu-nightly-off.yaml): a CronJob scales deploy/vllm to 0 at 06:00 UTC and
# Karpenter consolidates the empty GPU node away. The previous EventBridge
# Scheduler (which force-scaled the static node group) was removed with the
# node group — under Karpenter, node-level scaling is futile: the controller
# re-provisions capacity for any pod that still wants a GPU.
