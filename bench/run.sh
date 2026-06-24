#!/usr/bin/env bash
# Run the in-cluster cost/latency benchmark and write results under
# bench/reports/runs/<ts>/. Usage: ./run.sh [config.json]
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-kelsus-dev}" AWS_REGION="${AWS_REGION:-us-east-1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CFG="${1:-$ROOT/bench/configs/qwen25-vl-7b.json}"
TS="$(date +%Y%m%dT%H%M%S)"
OUT="$ROOT/bench/reports/runs/$TS"
mkdir -p "$OUT"

kubectl create configmap bench-loadgen \
  --from-file=loadgen.py="$ROOT/bench/loadgen.py" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl delete job bench --ignore-not-found >/dev/null 2>&1

kubectl apply -f "$ROOT/bench/job-dev.yaml" >/dev/null
echo "==> running in-cluster load test (this takes a few minutes) ..."
kubectl wait --for=condition=complete job/bench --timeout=1200s >/dev/null 2>&1 \
  || kubectl wait --for=condition=failed job/bench --timeout=5s >/dev/null 2>&1 || true

kubectl logs job/bench > "$OUT/raw.log" 2>&1
python3 "$ROOT/bench/postprocess.py" "$OUT/raw.log" "$CFG" "$OUT"
echo ""
echo "==> results -> $OUT/{summary.json,results.csv}"
