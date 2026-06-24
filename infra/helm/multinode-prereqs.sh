#!/usr/bin/env bash
# Cluster prerequisites for the GLM-5.2 multi-node serve. Idempotent; run once per
# cluster AFTER `tofu apply` + karpenter-install.sh. These are the cluster add-on
# layer the multi-node LeaderWorkerSet (vllm-glm-52-multinode.yaml) depends on, and
# are NOT in the AMI or Terraform. Every step here fixes a gap found the hard way on
# the first real bring-up (2026-06-22) — see docs/glm52-multinode-runbook.md.
#
# Usage:
#   CTX=west2 AWS_REGION=us-west-2 TF_DIR=infra/terraform/envs/scale \
#     ./infra/helm/multinode-prereqs.sh
set -euo pipefail
CTX="${CTX:?set CTX = the kubectl context (e.g. west2)}"
REGION="${AWS_REGION:?set AWS_REGION}"
TF_DIR="${TF_DIR:?set TF_DIR (e.g. infra/terraform/envs/scale)}"
export AWS_PROFILE="${AWS_PROFILE:-kelsus-dev}"
HERE="$(cd "$(dirname "$0")" && pwd)"
TOFU="$(command -v tofu || echo "$HOME/.local/bin/tofu")"
K="kubectl --context $CTX"
H="helm --kube-context $CTX"

echo "==> [1/5] NVIDIA device plugin (advertises nvidia.com/gpu)"
# The EKS NVIDIA AL2023 AMI ships GPU DRIVERS but NOT the k8s device plugin, so without
# this a GPU node comes up Ready yet never advertises nvidia.com/gpu and pods can't schedule.
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin >/dev/null 2>&1 || true
helm repo update nvdp >/dev/null 2>&1
cat > /tmp/nvdp-values.yaml <<'EOF'
nodeSelector: { nvidia.com/gpu.present: "true" }
tolerations:
  - { key: nvidia.com/gpu, operator: Exists, effect: NoSchedule }
EOF
$H upgrade --install nvdp nvdp/nvidia-device-plugin \
  --namespace nvidia-device-plugin --create-namespace --version 0.17.4 -f /tmp/nvdp-values.yaml

echo "==> [2/5] EFA device plugin (advertises vpc.amazonaws.com/efa) + GPU-taint toleration"
# The chart's pods do NOT tolerate the nvidia.com/gpu taint by default, so the daemonset
# computes DESIRED=0 on the GPU nodes and EFA is never advertised -> pods stay Pending.
# Pass the toleration THROUGH helm values (the chart exposes top-level `tolerations:`),
# NOT a `kubectl patch` — a patch makes helm's field-manager conflict on every re-run.
helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update eks >/dev/null 2>&1
cat > /tmp/efa-values.yaml <<'EOF'
tolerations:
  - { key: nvidia.com/gpu, operator: Exists, effect: NoSchedule }
  - { operator: Exists }
EOF
$H upgrade --install aws-efa-k8s-device-plugin eks/aws-efa-k8s-device-plugin \
  --namespace kube-system --version 0.5.29 -f /tmp/efa-values.yaml

echo "==> [3/5] LeaderWorkerSet controller v0.9.0"
$H upgrade --install lws oci://registry.k8s.io/lws/charts/lws \
  --version 0.9.0 --namespace lws-system --create-namespace 2>&1 | tail -1 || true

echo "==> [4/5] gpu-h200 NodePool (p5e/p5en, EFA, 2-node limit) + bench SA + dead-man"
NODE_ROLE="$($TOFU -chdir="$TF_DIR" output -raw karpenter_node_role_name)"
CLUSTER="$($TOFU -chdir="$TF_DIR" output -raw cluster_name)"
sed -e "s/__NODE_ROLE__/$NODE_ROLE/g" -e "s/__CLUSTER__/$CLUSTER/g" \
  "$HERE/karpenter-nodepool-h200.yaml" | $K apply -f -
$K create serviceaccount bench -n default 2>/dev/null || true   # pod-identity assoc is in Terraform; the SA object is not
$K apply -f "$HERE/lws-deadman.yaml"                            # GPU cost backstop for the LWS

echo "==> [5/5] validate (fail loud if a prereq is missing)"
$K get crd leaderworkersets.leaderworkerset.x-k8s.io >/dev/null && echo "  LWS CRD ok"
$K -n nvidia-device-plugin get ds nvdp-nvidia-device-plugin >/dev/null && echo "  nvidia plugin ok"
$K -n kube-system get ds aws-efa-k8s-device-plugin >/dev/null && echo "  efa plugin ok (toleration patched)"
$K get nodepool gpu-h200 -o jsonpath='  gpu-h200 limits = {.spec.limits}{"\n"}'
LIM=$($K get nodepool gpu-h200 -o jsonpath='{.spec.limits.cpu}')
[ "${LIM:-0}" -ge 384 ] 2>/dev/null && echo "  nodepool allows 2 nodes ok" || echo "  WARN: gpu-h200 cpu limit ($LIM) < 384 — only ONE p5e will launch"
echo ""
echo "==> prereqs installed. A GPU node that lands MUST advertise BOTH nvidia.com/gpu and"
echo "    vpc.amazonaws.com/efa before the LWS pods schedule. After capacity lands, verify:"
echo "    $K get nodes -l nvidia.com/gpu.present=true -o custom-columns=NAME:.metadata.name,GPU:'.status.allocatable.nvidia\\.com/gpu',EFA:'.status.allocatable.vpc\\.amazonaws\\.com/efa'"
