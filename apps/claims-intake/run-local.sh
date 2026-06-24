#!/usr/bin/env bash
# Run claims-intake extraction from your laptop against the in-cluster vLLM
# via a temporary local port-forward.
#   ./run-local.sh 20      # score 20 invoices
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-kelsus-dev}" AWS_REGION="${AWS_REGION:-us-east-1}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PF='kubectl.*port-forward.*svc/vllm'

pkill -f "$PF" 2>/dev/null || true
kubectl -n default port-forward --address 127.0.0.1 svc/vllm 8000:8000 >/tmp/pf-vllm.log 2>&1 &
trap 'pkill -f "$PF" 2>/dev/null || true' EXIT
curl -sf --retry 60 --retry-delay 1 --retry-connrefused http://127.0.0.1:8000/health >/dev/null

python3 "$ROOT/apps/claims-intake/extract.py" "$@"
