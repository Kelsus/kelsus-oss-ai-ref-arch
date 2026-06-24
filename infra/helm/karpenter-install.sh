#!/usr/bin/env bash
# Install the Karpenter controller (runs on the CPU nodes) and apply the GPU
# NodePool/EC2NodeClass. IAM/queue/discovery-tags come from Terraform
# (modules/refarch-stack -> module.karpenter). Idempotent.
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-kelsus-dev}" AWS_REGION="${AWS_REGION:-us-east-1}"
HERE="$(cd "$(dirname "$0")" && pwd)"
TF_DIR="${TF_DIR:-$HERE/../terraform/envs/dev}" # envs/scale for the benchmark cluster
CLUSTER="${CLUSTER:-kelsus-refarch-dev}"
CHART_VERSION="${CHART_VERSION:-1.1.1}" # supports k8s 1.31

TOFU="$(command -v tofu || echo "$HOME/.local/bin/tofu")"
QUEUE="$($TOFU -chdir="$TF_DIR" output -raw karpenter_queue_name)"
NODE_ROLE="$($TOFU -chdir="$TF_DIR" output -raw karpenter_node_role_name)"
echo "==> cluster=$CLUSTER queue=$QUEUE node_role=$NODE_ROLE chart=$CHART_VERSION"

helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "$CHART_VERSION" \
  --namespace kube-system \
  --set "settings.clusterName=$CLUSTER" \
  --set "settings.interruptionQueue=$QUEUE" \
  --set controller.resources.requests.cpu=250m \
  --set controller.resources.requests.memory=512Mi \
  --set replicas=1 \
  --wait

echo "==> applying GPU NodePool + EC2NodeClass"
sed -e "s/__NODE_ROLE__/$NODE_ROLE/g" -e "s/__CLUSTER__/$CLUSTER/g" \
  "$HERE/karpenter-nodepool.yaml" | kubectl apply -f -

kubectl get nodepools,ec2nodeclasses 2>/dev/null || true
echo "==> done. A Pending GPU pod now provisions a g6e node; empty nodes consolidate after 5m."
