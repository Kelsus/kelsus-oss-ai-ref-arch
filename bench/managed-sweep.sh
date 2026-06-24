#!/usr/bin/env bash
# Managed-provider quality sweep. For each model in bench/configs/managed-sweep.txt:
#   1. point the gateway at it   (kubectl set env deploy/gateway PROVIDER=... *_MODEL_ID=...)
#   2. wait for the rollout, warm it
#   3. submit the managed quality Job (bench/job-quality-managed.yaml, RAG_COLLECT=1)
#   4. poll to completion; the Job uploads managed-<label>-<ts>.json to S3
# Restores PROVIDER=local on exit. GPU-free — the gateway is always-up CPU; the
# Qwen2.5-72B fixed-judge pass scores the collected RAG answers later.
#
# Prereqs: gateway deployed with provider routing (apps/gateway/deploy.sh) and the
# gateway Pod-Identity applied (tofu apply); corpus ingested (make rag-ingest);
# eval data in S3 (run with 'sync' once). Anthropic rows also need the
# anthropic-api-key secret (Jon creates it).
#
#   ./managed-sweep.sh [sync]        # 'sync' re-uploads eval data+code to S3 first
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-kelsus-dev}" AWS_REGION="${AWS_REGION:-us-west-2}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="${BUCKET:-kelsus-refarch-models-scale-${ACCOUNT}}"   # scale cluster (us-west-2) is the only live cluster
CONF="${CONF:-$ROOT/bench/configs/managed-sweep.txt}"
WORKERS="${WORKERS:-8}"               # gentle on managed-API rate limits
RAG_COLLECT="${RAG_COLLECT:-1}"       # collect answers; judge later with the fixed judge
N="${N:-0}"; QN="${QN:-0}"            # 0 = full eval set; set small (e.g. 10) for a smoke

if [ "${1:-}" = "sync" ]; then
  echo "==> syncing eval data + code -> s3://$BUCKET/eval/"
  B="s3://$BUCKET/eval"
  aws s3 sync "$ROOT/data/synthea/output/forms"      "$B/data/synthea/output/forms" --only-show-errors
  aws s3 sync "$ROOT/data/synthea/output/forms-scan" "$B/data/synthea/output/forms-scan" --only-show-errors
  aws s3 sync "$ROOT/data/gold/claims"               "$B/data/gold/claims" --only-show-errors
  aws s3 sync "$ROOT/data/fatura/output"             "$B/data/fatura/output" --only-show-errors
  aws s3 sync "$ROOT/data/fatura/gold"               "$B/data/fatura/gold" --only-show-errors
  for f in eval_manifest.jsonl eval_manifest_commercial.jsonl rag_gold.json score.py judge.py; do
    aws s3 cp "$ROOT/bench/quality/$f" "$B/bench/quality/" --only-show-errors
  done
  aws s3 cp "$ROOT/bench/stats.py" "$B/bench/" --only-show-errors
fi

restore() {
  echo "==> restoring gateway to PROVIDER=local"
  kubectl set env deploy/gateway PROVIDER=local BEDROCK_MODEL_ID- ANTHROPIC_MODEL_ID- LLM_MAX_TOKENS- >/dev/null 2>&1 || true
}
trap restore EXIT

run_one() {  # provider model label tiers skip_commercial
  local provider="$1" model="$2" label="$3" tiers="$4" skipc="$5"
  echo "=== $label  ($provider: $model) ==="
  # LLM_MAX_TOKENS=1024: headroom for reasoning models (DeepSeek-V3.2/GLM-4.7/Kimi)
  # whose output can exceed the local default of 400; harmless for non-reasoning ones.
  if [ "$provider" = "bedrock" ]; then
    kubectl set env deploy/gateway PROVIDER=bedrock BEDROCK_MODEL_ID="$model" ANTHROPIC_MODEL_ID- LLM_MAX_TOKENS=1024 >/dev/null
  else
    kubectl set env deploy/gateway PROVIDER=anthropic ANTHROPIC_MODEL_ID="$model" BEDROCK_MODEL_ID- LLM_MAX_TOKENS=1024 >/dev/null
  fi
  kubectl rollout status deploy/gateway --timeout=180s >/dev/null

  kubectl delete job bench-quality-managed --ignore-not-found >/dev/null 2>&1
  sed -e "s/__BUCKET__/$BUCKET/g" \
      -e "s/__WORKERS__/$WORKERS/g" \
      -e "s/__EXTRACT_TIMEOUT__/${EXTRACT_TIMEOUT:-300}/g" \
      -e "s/__RAG_TIMEOUT__/${RAG_TIMEOUT:-180}/g" \
      -e "s/__N__/$N/g" -e "s/__QN__/$QN/g" \
      -e "s/__RAG_COLLECT__/$RAG_COLLECT/g" \
      -e "s/__TIERS__/$tiers/g" \
      -e "s/__SKIP_COMMERCIAL__/$skipc/g" \
      -e "s/__SKIP_EXTRACTION__/${SKIP_EXTRACTION:-}/g" \
      -e "s/__SKIP_RAG__/${SKIP_RAG:-}/g" \
      -e "s/__MODEL_LABEL__/$label/g" \
      "$ROOT/bench/job-quality-managed.yaml" | kubectl apply -f - >/dev/null

  # Poll to completion (watches drop silently under load — SE-10).
  for _ in $(seq 1 240); do   # up to ~2h
    s="$(kubectl get job bench-quality-managed -o jsonpath='{.status.succeeded} {.status.failed}' 2>/dev/null || true)"
    case "$s" in
      "1 "*) echo "  done: $label"; return 0 ;;
      *" 1") echo "  FAILED: $label (see s3://$BUCKET/results/logs/managed-$label-*.txt)"; return 1 ;;
    esac
    sleep 30
  done
  echo "  TIMEOUT waiting on $label"; return 1
}

while IFS='|' read -r provider model label tiers skipc; do
  case "$provider" in ''|\#*) continue;; esac
  run_one "$provider" "$model" "$label" "$tiers" "$skipc" || true   # keep going on a single failure
done < "$CONF"

echo "==> managed sweep complete. Results: s3://$BUCKET/results/quality/managed-*.json"
echo "    Next: fixed-judge pass (Qwen2.5-72B) over the collected RAG answers."
