#!/usr/bin/env bash
# Nemotron-3-Ultra-550B (NVFP4) quality — laptop-independent, modeled on run-ornith.sh.
#
# Nemotron-3-Ultra is TEXT-ONLY (hybrid Mamba-2 + Transformer + MoE) and a reasoning
# model, served NVFP4 on a single 8xH100 box via the Marlin FP4 fallback (see
# infra/helm/vllm-nemotron-ultra.yaml):
#   - text-only  -> clean-digital extraction + RAG-collect (TIERS=clean-digital,
#                   SKIP_COMMERCIAL=1), like the other text models (GLM, DeepSeek, Kimi).
#   - reasoning + Marlin-FP4-on-Hopper is slow -> generous timeouts, low concurrency.
#
# SMOKE FIRST. This stacks several first-time unknowns (NemotronH hybrid arch + NVFP4 on
# Hopper + Mamba kernels). Confirm the serve actually generates one completion, and check
# whether it emits a <think> block (reasoning mode), BEFORE submitting the eval — see
# docs/nemotron-benchmark-runbook.md. Do not blind-submit this onto a fresh serve.
#
# Flow (same as the Ornith reliable runner):
#   - arm the nightly gpu-off belt; apply the manifest (H100-pinned); scale to 1
#   - submit ONE in-cluster eval Job (bench/job-quality.yaml): it waits for vLLM, scores
#     clean-digital extraction + RAG-collect, ships to S3, releases the GPU (vllm->0) on exit.
set -uo pipefail
cd "$(dirname "$0")/.."
export AWS_PROFILE=kelsus-dev KUBECONFIG=/tmp/kubeconfig-scale AWS_REGION=us-west-2
ACCT=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="kelsus-refarch-models-scale-$ACCT"
st() { bash bench/status.sh set "$1" >/dev/null 2>&1 || true; echo ">> $1"; }

st "nemotron: ensure nightly GPU belt is armed"
kubectl apply -f infra/helm/gpu-nightly-off.yaml >/dev/null 2>&1

st "nemotron: deploying Nemotron-3-Ultra-550B NVFP4 (NemotronH hybrid Mamba-MoE, TP=8 on 8xH100)"
kubectl apply -f infra/helm/vllm-nemotron-ultra.yaml >/dev/null 2>&1
kubectl scale deploy/vllm --replicas=1 >/dev/null 2>&1

st "nemotron: submitting eval Job — clean-digital extraction + RAG-collect, reasoning timeouts"
# Text model => TIERS=clean-digital, SKIP_COMMERCIAL=1. Reasoning + Marlin-FP4-on-Hopper is
# slow => 1200s timeouts, WORKERS=2. The in-cluster Job waits for vLLM, scores, ships to S3,
# and self-releases the GPU (scale deploy/vllm -> 0) — laptop-independent.
N=0 QN=0 RAG_COLLECT=1 TIERS=clean-digital SKIP_COMMERCIAL=1 \
  WORKERS=2 EXTRACT_TIMEOUT=1200 RAG_TIMEOUT=1200 bash bench/run-quality-incluster.sh >/dev/null 2>&1

st "nemotron: eval submitted. Result -> S3, GPU self-releases on finish. DISCONNECT-SAFE. (make status / make quality-results)"
echo "NEMOTRON_HANDOFF_DONE"
