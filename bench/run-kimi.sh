#!/usr/bin/env bash
# Kimi-K2-Instruct (RedHat w4a16) on 8×H200 — LAPTOP-INDEPENDENT.
#
# The laptop only does instant API calls then exits; everything that waits runs
# IN-CLUSTER, so the run survives the laptop sleeping (the failure that killed the
# last Kimi attempt — SE-20):
#   - deploy vLLM (Karpenter provisions H200; ~1h to download 547GB)
#   - arm the per-run deadline Job (in-cluster cost belt, 6h)
#   - submit the eval Job, which WAITS in-cluster for vLLM to serve, then scores,
#     uploads to S3, and self-releases the GPU on exit
# Cost belts: per-run deadline (primary) + nightly dead-man (global, now CONDITIONAL
# so it won't kill this run mid-download). make status / make quality-results.
set -uo pipefail
cd "$(dirname "$0")/.."
export AWS_PROFILE=kelsus-dev KUBECONFIG=/tmp/kubeconfig-scale AWS_REGION=us-west-2
ACCT=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="kelsus-refarch-models-scale-$ACCT"
TOFU="$(command -v tofu || echo "$HOME/.local/bin/tofu")"
st() { bash bench/status.sh set "$1" >/dev/null 2>&1 || true; echo ">> $1"; }

st "kimi: belts — conditional nightly dead-man + fresh 6h per-run deadline"
kubectl apply -f infra/helm/gpu-nightly-off.yaml >/dev/null 2>&1   # conditional (skips active eval)
kubectl delete job gpu-deadline --ignore-not-found >/dev/null 2>&1
kubectl apply -f infra/helm/gpu-deadline-job.yaml >/dev/null 2>&1  # in-cluster 6h cost belt

st "kimi: H200 NodePool + deploy Kimi-K2-Instruct w4a16 (vLLM 0.10.0)"
NODE_ROLE="$($TOFU -chdir=infra/terraform/envs/scale output -raw karpenter_node_role_name)"
sed -e "s/__NODE_ROLE__/$NODE_ROLE/g" -e "s/__CLUSTER__/kelsus-refarch-scale/g" \
  infra/helm/karpenter-nodepool-h200.yaml | kubectl apply -f - >/dev/null 2>&1
kubectl apply -f infra/helm/vllm-kimi.yaml >/dev/null 2>&1
kubectl scale deploy/vllm --replicas=1 >/dev/null 2>&1

st "kimi: submitting eval Job (waits IN-CLUSTER for vLLM, then scores+uploads+self-releases)"
# Submitted BEFORE vLLM serves — the Job waits in-cluster through the ~1h download,
# so the laptop is no longer in the loop after this point.
N=0 QN=0 RAG_COLLECT=1 TIERS=clean-digital SKIP_COMMERCIAL=1 \
  WORKERS=2 EXTRACT_TIMEOUT=600 RAG_TIMEOUT=600 bash bench/run-quality-incluster.sh >/dev/null 2>&1

st "kimi: fully handed off to cluster. Laptop may sleep. Result -> S3; GPU self-releases; deadline belt armed."
echo "KIMI_HANDOFF_DONE"
