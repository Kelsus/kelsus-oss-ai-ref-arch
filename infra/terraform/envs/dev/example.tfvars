# Copy to dev.tfvars and adjust as needed. dev.tfvars is gitignored.
region       = "us-east-1"
aws_profile  = "kelsus-dev"
env          = "dev"
cluster_name = "kelsus-refarch-dev"

# GPU capacity is managed by Karpenter (infra/helm/karpenter-nodepool.yaml);
# on/off = make gpu-resume / gpu-pause (scales the vLLM deployment).

# dev keeps NAT + public API endpoint for convenience.
# The sovereign posture (no egress) is exercised in envs/scale.
enable_nat_gateway             = true
cluster_endpoint_public_access = true
