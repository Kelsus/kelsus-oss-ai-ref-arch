#!/usr/bin/env bash
# Run the sovereign-rag pipeline from your laptop against the in-cluster
# services (vLLM, embeddings, pgvector) via temporary local port-forwards.
# All traffic stays between your machine and the cluster API; nothing public.
#
# Usage:  ./run-local.sh init
#         ./run-local.sh ingest data/corpus/seed
#         ./run-local.sh ask "What has the CFPB proposed about overdraft fees?"
set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-kelsus-dev}" AWS_REGION="${AWS_REGION:-us-east-1}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PF='kubectl.*port-forward.*svc/(vllm|embeddings|pgvector)'

# Local ports chosen to avoid common collisions (e.g. a local Postgres on 5432).
# Password is read from the in-cluster `rag-db` secret (no creds in the repo);
# the DSN itself carries none — libpq/psycopg2 picks up PGPASSWORD.
export PGPASSWORD="${PGPASSWORD:-$(kubectl get secret rag-db -o jsonpath='{.data.password}' 2>/dev/null | base64 --decode)}"
export PG_DSN="${PG_DSN:-postgresql://rag@127.0.0.1:55432/rag}"

pkill -f "$PF" 2>/dev/null || true
kubectl -n default port-forward --address 127.0.0.1 svc/vllm       8000:8000  >/tmp/pf-vllm.log  2>&1 &
kubectl -n default port-forward --address 127.0.0.1 svc/embeddings 8081:80    >/tmp/pf-embed.log 2>&1 &
kubectl -n default port-forward --address 127.0.0.1 svc/pgvector   55432:5432 >/tmp/pf-pg.log    2>&1 &
trap 'pkill -f "$PF" 2>/dev/null || true' EXIT

echo "==> waiting for tunnels (vLLM, embeddings, pgvector) ..."
curl -sf --retry 60 --retry-delay 1 --retry-connrefused http://127.0.0.1:8000/health >/dev/null
curl -sf --retry 60 --retry-delay 1 --retry-connrefused http://127.0.0.1:8081/health >/dev/null
python3 - <<'PY'
import socket, time
for _ in range(60):
    try:
        socket.create_connection(("127.0.0.1", 55432), 2).close(); break
    except OSError:
        time.sleep(1)
PY

python3 "$ROOT/apps/sovereign-rag/rag.py" "$@"
