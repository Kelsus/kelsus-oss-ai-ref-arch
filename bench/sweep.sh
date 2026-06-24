#!/usr/bin/env bash
# Multi-model sweep: for each model, patch the vLLM Deployment to serve it, wait
# for the rollout, run the in-cluster cost/latency bench, and collect. Restores
# the original model on exit. Builds a comparison table.
#
#   ./sweep.sh                       # uses bench/configs/sweep-dev.txt
#   ./sweep.sh Qwen/Qwen2.5-7B-Instruct microsoft/Phi-3.5-mini-instruct
#
# NOTE: each model is downloaded + loaded (minutes) and the live model is
# swapped, so the chat/RAG/extract demo is interrupted for the duration.
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-kelsus-dev}" AWS_REGION="${AWS_REGION:-us-east-1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

MODELS=()
if [ "$#" -gt 0 ]; then
  MODELS=("$@")
else
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue;; esac
    MODELS+=("$line")
  done < "$ROOT/bench/configs/sweep-dev.txt"
fi

TS="$(date +%Y%m%dT%H%M%S)"
SWEEP="$ROOT/bench/reports/sweeps/$TS"; mkdir -p "$SWEEP"
ORIG="$(kubectl get deploy vllm -o jsonpath='{.spec.template.spec.containers[0].args[1]}')"
echo "current model (restored on exit): $ORIG"
restore() { kubectl patch deploy vllm --type=json \
  -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args/1\",\"value\":\"$ORIG\"}]" >/dev/null \
  && echo "restored $ORIG"; }
trap restore EXIT

for M in "${MODELS[@]}"; do
  echo "=== $M ==="
  kubectl patch deploy vllm --type=json \
    -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args/1\",\"value\":\"$M\"}]" >/dev/null
  if ! kubectl rollout status deploy/vllm --timeout=1200s >/dev/null 2>&1; then
    echo "  rollout failed (OOM / unsupported / gated?), skipping $M"; continue
  fi
  bash "$ROOT/bench/run.sh" >/dev/null 2>&1 || true
  LATEST="$(ls -d "$ROOT"/bench/reports/runs/*/ | tail -1)"
  SAFE="$(echo "$M" | tr '/' '_')"
  cp "${LATEST}summary.json" "$SWEEP/$SAFE.json" 2>/dev/null && echo "  recorded $SAFE"
done

python3 "$ROOT/bench/compare.py" "$SWEEP" | tee "$SWEEP/comparison.md"
echo "sweep -> $SWEEP"
