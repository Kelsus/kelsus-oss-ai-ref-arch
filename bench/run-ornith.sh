#!/usr/bin/env bash
# Ornith-1.0-397B quality — laptop-independent, modeled on run-deepseek-reliable.sh.
#
# Ornith is a VISION + REASONING MoE (see infra/helm/vllm-ornith.yaml):
#   - vision    -> full extraction tiers (clean..degraded) + the FATURA commercial
#                  set, so TIERS is empty (all) and SKIP_COMMERCIAL is empty (run it),
#                  unlike the text-only DeepSeek/GLM/Kimi runs (clean-digital only).
#   - reasoning -> long <think> blocks: generous per-request timeouts and modest
#                  concurrency, and the request token ceiling must clear reasoning
#                  + answer (the GLM-5.2 truncation lesson — verify in the smoke test).
#
# Flow (one owner per concern, same as the DeepSeek reliable runner):
#   - arm the nightly gpu-off belt
#   - apply vllm-ornith.yaml (H200/p5e-pinned), scale to 1
#   - submit ONE in-cluster eval Job (bench/job-quality.yaml): it waits up to ~3.5h
#     for vLLM, scores extraction across all tiers + commercial, COLLECTS RAG answers,
#     ships log+result to S3, and RELEASES the GPU (vllm->0) on exit. The laptop can
#     disconnect the moment the Job is submitted.
# Belt: the nightly gpu-off CronJob (global). No per-run timer, no watcher Job.
#
# Follow-on passes (separate, documented in docs/ornith-benchmark-runbook.md):
#   - fixed-judge RAG scoring: swap vllm -> Qwen2.5-VL-72B (vllm-scale.yaml) and score
#     the collected answers, so Ornith's RAG number uses the SAME judge as the lineup
#     (not self-judged — the self-judge bias was ~9 pts).
#   - cost/latency: `make bench` (loadgen peak throughput -> $/M). Expect a reasoning tax.
set -uo pipefail
cd "$(dirname "$0")/.."
export AWS_PROFILE=kelsus-dev KUBECONFIG=/tmp/kubeconfig-scale AWS_REGION=us-west-2
ACCT=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="kelsus-refarch-models-scale-$ACCT"
st() { bash bench/status.sh set "$1" >/dev/null 2>&1 || true; echo ">> $1"; }

st "ornith: ensure nightly GPU belt is armed"
kubectl apply -f infra/helm/gpu-nightly-off.yaml >/dev/null 2>&1

st "ornith: deploying Ornith-1.0-397B BF16 (qwen3_5_moe, vision+reasoning, TP=8 on 8xH200)"
kubectl apply -f infra/helm/vllm-ornith.yaml >/dev/null 2>&1
kubectl scale deploy/vllm --replicas=1 >/dev/null 2>&1

st "ornith: submitting eval Job — full vision tiers + FATURA commercial, RAG-collect, reasoning timeouts"
# Vision => TIERS/SKIP_COMMERCIAL empty (all tiers + commercial). Reasoning => 900s
# timeouts and WORKERS=2 (one 397B box; keep concurrency modest so long-CoT, image-
# bearing requests don't queue-starve or OOM the KV cache). The in-cluster Job waits
# for vLLM, scores, ships to S3, and self-releases the GPU — laptop-independent.
N=0 QN=0 RAG_COLLECT=1 TIERS= SKIP_COMMERCIAL= \
  WORKERS=2 EXTRACT_TIMEOUT=900 RAG_TIMEOUT=900 bash bench/run-quality-incluster.sh >/dev/null 2>&1

st "ornith: eval submitted. Result -> S3, GPU self-releases on finish. DISCONNECT-SAFE. (make status / make quality-results)"
echo "ORNITH_HANDOFF_DONE"
