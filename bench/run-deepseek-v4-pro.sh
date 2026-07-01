#!/usr/bin/env bash
# DeepSeek-V4-Pro quality — laptop-independent, modeled on run-nemotron.sh.
#
# DeepSeek-V4-Pro is TEXT-ONLY (1.6T MoE / 49B active, hybrid CSA+HCA sparse attention)
# and a REASONING model, served as the native FP4+FP8 mixed checkpoint on a single 8xH200
# box (TP=8) via the Marlin FP4 fallback for the experts (see vllm-deepseek-v4-pro.yaml):
#   - text-only  -> clean-digital extraction + RAG-collect (TIERS=clean-digital,
#                   SKIP_COMMERCIAL=1), like the other text models (GLM, DeepSeek-V3.2,
#                   Kimi, Nemotron).
#   - reasoning + Marlin-FP4-on-Hopper is slow -> generous timeouts, low concurrency.
#
# SMOKE FIRST. This stacks several first-time unknowns (DeepseekV4ForCausalLM arch in
# v0.23.0 + CSA/HCA + FP4 experts on Hopper + 865GB on one box). Confirm the serve loads
# and generates ONE completion, and that --reasoning-parser deepseek_v4 strips the
# reasoning so the visible content is the answer, BEFORE submitting the eval -- see
# docs/deepseek-v4-pro-benchmark-runbook.md. If v0.23.0 rejects the arch or the FP4/MXFP4
# indexer kernels, pin a vLLM nightly (the GLM-5.2 lesson). Do not blind-submit.
#
# Flow (same as the Nemotron / Ornith reliable runners):
#   - arm the nightly gpu-off belt; apply the manifest (H200-pinned); scale to 1
#   - submit ONE in-cluster eval Job (bench/job-quality.yaml): it waits for vLLM, scores
#     clean-digital extraction + RAG-collect, ships to S3, releases the GPU (vllm->0) on exit.
set -uo pipefail
cd "$(dirname "$0")/.."
export AWS_PROFILE=kelsus-dev KUBECONFIG=/tmp/kubeconfig-scale AWS_REGION=us-west-2
ACCT=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="kelsus-refarch-models-scale-$ACCT"
st() { bash bench/status.sh set "$1" >/dev/null 2>&1 || true; echo ">> $1"; }

st "v4-pro: ensure nightly GPU belt is armed"
kubectl apply -f infra/helm/gpu-nightly-off.yaml >/dev/null 2>&1

st "v4-pro: deploying DeepSeek-V4-Pro FP4+FP8 (DeepseekV4 CSA+HCA reasoning MoE, TP=8 on 8xH200)"
kubectl apply -f infra/helm/vllm-deepseek-v4-pro.yaml >/dev/null 2>&1
kubectl scale deploy/vllm --replicas=1 >/dev/null 2>&1

st "v4-pro: submitting eval Job — clean-digital extraction + RAG-collect, reasoning timeouts"
# Text model => TIERS=clean-digital, SKIP_COMMERCIAL=1. Reasoning + Marlin-FP4-on-Hopper is
# slow => 1200s timeouts, WORKERS=2. The in-cluster Job waits for vLLM, scores, ships to S3,
# and self-releases the GPU (scale deploy/vllm -> 0) — laptop-independent.
N=0 QN=0 RAG_COLLECT=1 TIERS=clean-digital SKIP_COMMERCIAL=1 \
  WORKERS=2 EXTRACT_TIMEOUT=1200 RAG_TIMEOUT=1200 bash bench/run-quality-incluster.sh >/dev/null 2>&1

st "v4-pro: eval submitted. Result -> S3, GPU self-releases on finish. DISCONNECT-SAFE. (make status / make quality-results)"
echo "V4_PRO_HANDOFF_DONE"
