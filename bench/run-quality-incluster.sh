#!/usr/bin/env bash
# Submit the quality eval as an in-cluster Job and DETACH. The Job pulls data
# from S3, scores against the in-cluster gateway/vLLM, and uploads results to
# s3://<bucket>/results/quality/. No laptop tunnel or SSO token is needed once
# submitted — fixes the "overnight run died with my SSO token" failure class.
#
# Usage:   ./run-quality-incluster.sh [sync]     # 'sync' re-uploads data+code first
# Harvest: make quality-results
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-kelsus-dev}" AWS_REGION="${AWS_REGION:-us-east-1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="${BUCKET:-kelsus-refarch-models-dev-${ACCOUNT}}" # scale cluster: kelsus-refarch-models-scale-<acct>

if [ "${1:-}" = "sync" ]; then
  echo "==> syncing eval data + code -> s3://$BUCKET/eval/"
  B="s3://$BUCKET/eval"
  aws s3 sync "$ROOT/data/synthea/output/forms"      "$B/data/synthea/output/forms" --only-show-errors
  aws s3 sync "$ROOT/data/synthea/output/forms-scan" "$B/data/synthea/output/forms-scan" --only-show-errors
  aws s3 sync "$ROOT/data/gold/claims"               "$B/data/gold/claims" --only-show-errors
  aws s3 sync "$ROOT/data/fatura/output"             "$B/data/fatura/output" --only-show-errors
  aws s3 sync "$ROOT/data/fatura/gold"               "$B/data/fatura/gold" --only-show-errors
  aws s3 cp "$ROOT/bench/quality/eval_manifest.jsonl"            "$B/bench/quality/" --only-show-errors
  aws s3 cp "$ROOT/bench/quality/eval_manifest_commercial.jsonl" "$B/bench/quality/" --only-show-errors
  aws s3 cp "$ROOT/bench/quality/rag_gold.json"                  "$B/bench/quality/" --only-show-errors
  aws s3 cp "$ROOT/bench/quality/score.py" "$B/bench/quality/" --only-show-errors
  aws s3 cp "$ROOT/bench/quality/judge.py" "$B/bench/quality/" --only-show-errors
  aws s3 cp "$ROOT/bench/stats.py"         "$B/bench/" --only-show-errors
fi

kubectl get serviceaccount bench >/dev/null 2>&1 || kubectl create serviceaccount bench
kubectl apply -f "$ROOT/infra/helm/bench-rbac.yaml" >/dev/null 2>&1  # SA bench may scale vllm to 0 on finish
kubectl delete job bench-quality --ignore-not-found >/dev/null 2>&1

sed -e "s/__BUCKET__/$BUCKET/g" \
    -e "s/__WORKERS__/${WORKERS:-16}/g" \
    -e "s/__EXTRACT_TIMEOUT__/${EXTRACT_TIMEOUT:-300}/g" \
    -e "s/__RAG_TIMEOUT__/${RAG_TIMEOUT:-180}/g" \
    -e "s/__N__/${N:-0}/g" \
    -e "s/__QN__/${QN:-0}/g" \
    -e "s/__RAG_COLLECT__/${RAG_COLLECT:-}/g" \
    -e "s/__TIERS__/${TIERS:-}/g" \
    -e "s/__SKIP_COMMERCIAL__/${SKIP_COMMERCIAL:-}/g" \
    -e "s/__SKIP_EXTRACTION__/${SKIP_EXTRACTION:-}/g" \
    -e "s/__SKIP_RAG__/${SKIP_RAG:-}/g" \
    "$ROOT/bench/job-quality.yaml" | kubectl apply -f -
echo ""
echo "==> submitted. The Job runs autonomously in-cluster (no laptop needed)."
echo "    watch:   kubectl get pods -l job-name=bench-quality -w"
echo "    logs:    kubectl logs -f job/bench-quality"
echo "    results: make quality-results"
