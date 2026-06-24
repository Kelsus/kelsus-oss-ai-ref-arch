#!/usr/bin/env bash
# Deploy/update the in-cluster gateway. Code ships as a ConfigMap built from
# app.py; re-run after editing app.py to roll the new code.
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-kelsus-dev}" AWS_REGION="${AWS_REGION:-us-west-2}"
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"

# SA carries the Bedrock Pod-Identity role (Terraform). Safe to create if absent.
kubectl get serviceaccount gateway >/dev/null 2>&1 || kubectl create serviceaccount gateway

# rag-db secret (generated Postgres password; never committed, SOC2 CC6). Idempotent.
kubectl get secret rag-db >/dev/null 2>&1 || \
  kubectl create secret generic rag-db --from-literal=password="$(openssl rand -hex 16)"

kubectl create configmap gateway-app \
  --from-file=app.py="$DIR/app.py" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f "$ROOT/infra/helm/gateway-dev.yaml"
kubectl rollout restart deploy/gateway
kubectl rollout status deploy/gateway --timeout=300s
echo "gateway ready. Try:  make ask Q=\"...\"   or   make extract-api PDF=<file>"
