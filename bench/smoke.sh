#!/usr/bin/env bash
# End-to-end smoke test: prove both apps serve through the in-cluster gateway
# without leaving the VPC. Port-forwards the internal gateway, then hits /health,
# /rag/query (App 2), and /extract on a sample invoice (App 1). Requires the
# stack to be up (GPU resumed). Nothing is exposed publicly.
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-kelsus-dev}" AWS_REGION="${AWS_REGION:-us-east-1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

pkill -f "port-forward.*svc/gateway" 2>/dev/null || true
kubectl port-forward --address 127.0.0.1 svc/gateway 8088:8000 >/tmp/pf-smoke.log 2>&1 &
trap 'pkill -f "port-forward.*svc/gateway" 2>/dev/null || true' EXIT
curl -sf --retry 40 --retry-delay 1 --retry-connrefused http://127.0.0.1:8088/health >/dev/null \
  && echo "/health: OK"

echo "== /rag/query (App 2) =="
curl -fsS http://127.0.0.1:8088/rag/query -H 'content-type: application/json' \
  -d '{"q":"What has the CFPB proposed about overdraft fees?"}' \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print("  answer:", d["answer"][:120]); print("  citations:", len(d.get("citations",[])))'

echo "== /extract (App 1) =="
PDF=$(ls "$ROOT"/data/synthea/output/forms/*.pdf 2>/dev/null | head -1)
if [ -n "$PDF" ]; then
  curl -fsS -F "file=@$PDF" http://127.0.0.1:8088/extract \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print("  mode:", d.get("mode"), "| fields:", len(d.get("fields",{})))'
else
  echo "  (no sample invoice — run: make data-synthea)"
fi
echo "smoke OK"
