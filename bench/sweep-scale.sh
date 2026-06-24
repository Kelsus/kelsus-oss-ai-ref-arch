#!/usr/bin/env bash
# Scale-tier model sweep. For each MODEL|TP|GPUS|MAXLEN|CACHE|TIERS|EXTRA line:
# deploy via the template -> POLL until serving (SE-10: no long watches) ->
# in-cluster quality job (RAG answers COLLECTED, judged later by the fixed
# judge) -> next. Scales vLLM to 0 at the end. Designed to be killed/rerun:
# every stage is idempotent.
#
# Usage: KUBECONFIG=/tmp/kubeconfig-scale ./sweep-scale.sh sweep-tierA.conf
set -uo pipefail
cd "$(dirname "$0")/.."
export AWS_PROFILE="${AWS_PROFILE:-kelsus-dev}" AWS_REGION="${AWS_REGION:-us-west-2}"
CONF="${1:?usage: sweep-scale.sh <conf file>}"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="${BUCKET:-kelsus-refarch-models-scale-$ACCOUNT}"

poll_ready() {  # poll_ready <minutes> — generation-aware: a leftover READY pod
  # from the PREVIOUS model must not count (phantom-eval bug). --watch=false
  # checks the latest generation without holding a long watch (SE-10).
  local mins=$1
  for _ in $(seq 1 $((mins * 2))); do
    kubectl rollout status deploy/vllm --watch=false 2>/dev/null | grep -q "successfully rolled out" && return 0
    sleep 30
  done
  return 1
}

poll_job() {  # poll_job <name> <minutes>
  local name=$1 mins=$2
  for _ in $(seq 1 $((mins * 2))); do
    [ "$(kubectl get job "$name" -o jsonpath='{.status.succeeded}' 2>/dev/null)" = "1" ] && return 0
    [ -n "$(kubectl get job "$name" -o jsonpath='{.status.failed}' 2>/dev/null)" ] && return 1
    sleep 30
  done
  return 1
}

st() { BUCKET="$BUCKET" bash "$(dirname "$0")/status.sh" set "$1" >/dev/null 2>&1 || true; }

grep -vE '^\s*(#|$)' "$CONF" | while IFS='|' read -r MODEL TP GPUS MAXLEN CACHE TIERS EXTRA; do
  SLUG=$(echo "$MODEL" | tr '/' '_')
  echo "=== [$SLUG] deploy (TP=$TP, GPUS=$GPUS) ==="
  st "[$SLUG] deploying (TP=$TP)"
  if ! MODEL="$MODEL" TP="$TP" GPUS="$GPUS" MAXLEN="$MAXLEN" CACHE="$CACHE" EXTRA="$EXTRA" \
       python3 bench/render-vllm.py > /tmp/vllm-render.yaml; then
    echo "FAIL_RENDER [$SLUG]"; continue
  fi
  kubectl apply -f /tmp/vllm-render.yaml || { echo "FAIL_APPLY [$SLUG]"; continue; }
  kubectl scale deploy/vllm --replicas=1 >/dev/null 2>&1 || true

  echo "=== [$SLUG] waiting to serve (poll, up to 100 min: node + download + load) ==="
  if ! poll_ready 100; then
    echo "FAIL_SERVE [$SLUG] — skipping"; kubectl get pods -l app=vllm; kubectl get nodeclaims
    kubectl logs -l app=vllm --tail=8 2>/dev/null | tail -8
    continue
  fi

  if [ -n "${PERF_ONLY:-}" ]; then
    echo "=== [$SLUG] PERF_ONLY: skipping quality ==="
  else
  echo "=== [$SLUG] quality job (RAG collect mode; tiers=$TIERS) ==="
  kubectl delete job bench-quality --ignore-not-found >/dev/null 2>&1
  RAG_COLLECT=1 TIERS="$TIERS" SKIP_COMMERCIAL="${SKIP_COMMERCIAL:-1}" SKIP_EXTRACTION="${SKIP_EXTRACTION:-}" \
  WORKERS="${WORKERS:-16}" EXTRACT_TIMEOUT="${EXTRACT_TIMEOUT:-300}" RAG_TIMEOUT="${RAG_TIMEOUT:-180}" \
    bash bench/run-quality-incluster.sh | tail -1
  if poll_job bench-quality "${QUALITY_POLL_MIN:-150}"; then
    echo "OK [$SLUG] quality done"; st "[$SLUG] quality DONE"
  else
    echo "FAIL_QUALITY [$SLUG]"; st "[$SLUG] quality FAILED (incomplete)"; kubectl logs job/bench-quality --tail=8 2>/dev/null
  fi
  fi

  echo "=== [$SLUG] cost/latency ==="
  bash bench/run.sh "bench/configs/sweep/${SLUG}.json" 2>&1 | tail -6 || echo "(no per-model config; skipped)"
done

echo "=== sweep done; GPU off ==="
kubectl scale deploy/vllm --replicas=0
st "sweep complete; vllm scaled to 0"
echo "SWEEP_COMPLETE"
