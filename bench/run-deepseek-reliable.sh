#!/usr/bin/env bash
# DeepSeek-V3.1 quality — minimal, laptop-independent.
#
# Design (one owner per concern, after the multi-mechanism spaghetti was cut):
#   - deploy vLLM (p5-pinned), wait until it serves
#   - submit ONE self-contained in-cluster eval Job (bench/job-quality.yaml):
#       it scores, ships log+result to S3, and RELEASES the GPU (vllm->0) on exit
#   - that's it. The laptop can disconnect the moment the Job is submitted.
# Belt: the nightly gpu-off CronJob (global). No per-run timer, no watcher Job.
#
# Status is streamed to S3 (make status). Engine is proven stable at WORKERS=2
# (0 restarts, ~6s/RAG); no smoke gate — the harness fail-loud + quarantine
# handle a bad run, the self-release + nightly belt bound cost.
set -uo pipefail
cd "$(dirname "$0")/.."
export AWS_PROFILE=kelsus-dev KUBECONFIG=/tmp/kubeconfig-scale AWS_REGION=us-west-2
ACCT=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="kelsus-refarch-models-scale-$ACCT"
st() { bash bench/status.sh set "$1" >/dev/null 2>&1 || true; echo ">> $1"; }

st "deepseek: ensure nightly GPU belt is armed"
kubectl apply -f infra/helm/gpu-nightly-off.yaml >/dev/null 2>&1

st "deepseek: deploying DeepSeek-V3.1-AWQ — QuantTrio recipe (vLLM 0.9.2 + patches, TP=8, util 0.8, NO expert-parallel)"
kubectl apply -f infra/helm/vllm-deepseek.yaml >/dev/null 2>&1
kubectl scale deploy/vllm --replicas=1 >/dev/null 2>&1

st "deepseek: waiting for p5 + vLLM to serve (~45-60min model load)"
for _ in $(seq 1 130); do
  kubectl rollout status deploy/vllm --watch=false 2>/dev/null | grep -q "successfully rolled out" && break
  sleep 30
done
if ! kubectl rollout status deploy/vllm --watch=false 2>/dev/null | grep -q "successfully rolled out"; then
  st "FAIL: vLLM never served -> releasing GPU"; kubectl scale deploy/vllm --replicas=0 >/dev/null 2>&1; exit 1
fi

st "deepseek: vLLM serving — submitting self-contained eval Job (full extraction + RAG, WORKERS=2)"
# The Job uploads result+log to S3 and releases the GPU on exit. Laptop-independent now.
N=0 QN=0 RAG_COLLECT=1 TIERS=clean-digital SKIP_COMMERCIAL=1 \
  WORKERS=2 EXTRACT_TIMEOUT=600 RAG_TIMEOUT=600 bash bench/run-quality-incluster.sh >/dev/null 2>&1

st "deepseek: eval submitted. Result -> S3, GPU self-releases on finish. DISCONNECT-SAFE. (make status / make quality-results)"
echo "DEEPSEEK_HANDOFF_DONE"
