#!/usr/bin/env bash
# Kimi-K2-Instruct-0905 (RegeSha w4a16) — directional model-progression add.
# LAPTOP-INDEPENDENT, same shape as run-kimi.sh: laptop only deploys + submits;
# the eval Job waits in-cluster for vLLM, scores, uploads, self-releases.
# Quant caveat: RegeSha is community/unverified — inspect the collected RAG
# answers in the result for coherence before trusting the numbers (a bad quant
# shows up as gibberish answers).
set -uo pipefail
cd "$(dirname "$0")/.."
export AWS_PROFILE=kelsus-dev KUBECONFIG=/tmp/kubeconfig-scale AWS_REGION=us-west-2
ACCT=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="kelsus-refarch-models-scale-$ACCT"
TOFU="$(command -v tofu || echo "$HOME/.local/bin/tofu")"
st() { bash bench/status.sh set "$1" >/dev/null 2>&1 || true; echo ">> $1"; }

st "kimi0905: belts — conditional nightly dead-man + fresh 6h per-run deadline"
kubectl apply -f infra/helm/gpu-nightly-off.yaml >/dev/null 2>&1
kubectl delete job gpu-deadline --ignore-not-found >/dev/null 2>&1
kubectl apply -f infra/helm/gpu-deadline-job.yaml >/dev/null 2>&1

st "kimi0905: H200 NodePool + deploy Kimi-K2-Instruct-0905 RegeSha w4a16 (vLLM 0.10.0)"
NODE_ROLE="$($TOFU -chdir=infra/terraform/envs/scale output -raw karpenter_node_role_name)"
sed -e "s/__NODE_ROLE__/$NODE_ROLE/g" -e "s/__CLUSTER__/kelsus-refarch-scale/g" \
  infra/helm/karpenter-nodepool-h200.yaml | kubectl apply -f - >/dev/null 2>&1
kubectl apply -f infra/helm/vllm-kimi-0905.yaml >/dev/null 2>&1
kubectl scale deploy/vllm --replicas=1 >/dev/null 2>&1

st "kimi0905: submitting eval Job (waits IN-CLUSTER for vLLM, then scores+uploads+self-releases)"
N=0 QN=0 RAG_COLLECT=1 TIERS=clean-digital SKIP_COMMERCIAL=1 \
  WORKERS=2 EXTRACT_TIMEOUT=600 RAG_TIMEOUT=600 bash bench/run-quality-incluster.sh >/dev/null 2>&1

st "kimi0905: handed off to cluster. Laptop may sleep. INSPECT collected answers for quant sanity when result lands."
echo "KIMI0905_HANDOFF_DONE"
