#!/usr/bin/env bash
# Quality sweep: for each model, swap the vLLM Deployment, then score extraction
# F1 + RAG (fact coverage + grounding) through the gateway. Restores the
# original model on exit. One gateway tunnel for the whole run.
#   ./quality-sweep.sh            # uses bench/configs/sweep-dev.txt
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-kelsus-dev}" AWS_REGION="${AWS_REGION:-us-east-1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

python3 -c "import requests" 2>/dev/null || pip install -q requests

MODELS=()
if [ "$#" -gt 0 ]; then MODELS=("$@"); else
  while IFS= read -r line; do case "$line" in ''|\#*) continue;; esac; MODELS+=("$line"); done \
    < "$ROOT/bench/configs/sweep-dev.txt"
fi

TS="$(date +%Y%m%dT%H%M%S)"
SWEEP="$ROOT/bench/reports/quality/$TS"; mkdir -p "$SWEEP"
ORIG="$(kubectl get deploy vllm -o jsonpath='{.spec.template.spec.containers[0].args[1]}')"
echo "current model (restored on exit): $ORIG"

pkill -f "port-forward.*svc/gateway" 2>/dev/null || true
kubectl port-forward --address 127.0.0.1 svc/gateway 8088:8000 >/tmp/pf-gw.log 2>&1 &
cleanup() {
  kubectl patch deploy vllm --type=json \
    -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args/1\",\"value\":\"$ORIG\"}]" >/dev/null && echo "restored $ORIG"
  pkill -f "port-forward.*svc/gateway" 2>/dev/null || true
}
trap cleanup EXIT
curl -sf --retry 40 --retry-delay 1 --retry-connrefused http://127.0.0.1:8088/health >/dev/null

for M in "${MODELS[@]}"; do
  echo "=== $M ==="
  kubectl patch deploy vllm --type=json \
    -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args/1\",\"value\":\"$M\"}]" >/dev/null
  if ! kubectl rollout status deploy/vllm --timeout=1200s >/dev/null 2>&1; then
    echo "  rollout failed, skipping $M"; continue
  fi
  curl -s -X POST http://127.0.0.1:8088/rag/query -H 'content-type: application/json' \
    -d '{"q":"warmup"}' >/dev/null 2>&1 || true   # warm the new model
  GATEWAY=http://127.0.0.1:8088 python3 "$ROOT/bench/quality/score.py" > /tmp/q.out 2>/dev/null || true
  SAFE="$(echo "$M" | tr '/' '_')"
  M="$M" SAFE="$SAFE" SWEEP="$SWEEP" python3 - <<'PY'
import json, os, re
t = open("/tmp/q.out").read()
m = re.search(r"===QUALITY===\s*(\{.*?\})\s*===END===", t, re.S)
d = json.loads(m.group(1)) if m else {}
d["model"] = os.environ["M"]
json.dump(d, open(f'{os.environ["SWEEP"]}/{os.environ["SAFE"]}.json', "w"), indent=2)
print("  recorded:", d)
PY
done

python3 "$ROOT/bench/quality-compare.py" "$SWEEP" | tee "$SWEEP/comparison.md"
echo "quality sweep -> $SWEEP"
