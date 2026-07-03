#!/usr/bin/env bash
# RAG re-collection campaign (metric v2) — one model per invocation, serially.
#
#   bash bench/run-rag-recollect.sh <model-key>
#   bash bench/run-rag-recollect.sh --list
#
# Collects RAG answers ONLY (gold v2, 226 questions, context captured for the
# v2 judge): SKIP_EXTRACTION=1 SKIP_COMMERCIAL=1, RAG_COLLECT default. The
# in-cluster eval Job waits for vLLM, collects, ships to S3, and scales the GPU
# to 0 on exit. Belts: nightly-off + a fresh per-run deadline are (re)armed here.
#
# PREREQS (once per campaign): gateway redeployed from THIS branch's app.py
# (temp 0 + _context + LLM_MAX_TOKENS=2048) and eval assets synced to S3 —
# see docs/benchmarks (campaign runbook). Serves are SEQUENTIAL: one shared
# deploy/vllm + one bench-quality Job.
set -uo pipefail
cd "$(dirname "$0")/.."
export AWS_PROFILE="${AWS_PROFILE:-kelsus-dev}" KUBECONFIG="${KUBECONFIG:-/tmp/kubeconfig-scale}" AWS_REGION="${AWS_REGION:-us-west-2}"

# model-key -> manifest | workers | per-request timeout(s) | deadline(s) | notes
recipe() {
  case "$1" in
    kimi-k2-instruct) echo "infra/helm/vllm-kimi.yaml            8 600  21600" ;;
    llama4-scout)     echo "infra/helm/vllm-llama4-scout.yaml    8 600  21600" ;;
    qwen3-vl-235b)    echo "infra/helm/vllm-qwen3-vl-235b.yaml   8 600  21600" ;;
    qwen2.5-vl-72b)   echo "infra/helm/vllm-scale.yaml           8 600  21600" ;;  # g6e pool (ICE'd 2026-07-01; retry)
    glm-4.5-air)      echo "infra/helm/vllm-glm-45-air.yaml      4 1200 21600" ;;  # g6e pool; reasoning
    deepseek-v3.1)    echo "infra/helm/vllm-deepseek.yaml        4 1200 21600" ;;
    deepseek-v3.2)    echo "infra/helm/vllm-deepseek-v32.yaml    4 1200 21600" ;;
    glm-4.7)          echo "infra/helm/vllm-glm-47.yaml          4 1200 21600" ;;
    kimi-k2.5)        echo "infra/helm/vllm-kimi-k25.yaml        4 1200 43200" ;;  # 595GB pull
    ornith)           echo "infra/helm/vllm-ornith.yaml          2 900  43200" ;;  # 794GB BF16
    nemotron)         echo "infra/helm/vllm-nemotron-ultra.yaml  2 1200 43200" ;;
    glm-5.2)          echo "infra/helm/vllm-glm-52.yaml          2 1200 43200" ;;
    deepseek-v4-pro)  echo "infra/helm/vllm-deepseek-v4-pro.yaml 2 1200 43200" ;;  # 865GB
    *) return 1 ;;
  esac
}
KEYS="kimi-k2-instruct llama4-scout qwen3-vl-235b qwen2.5-vl-72b glm-4.5-air deepseek-v3.1 deepseek-v3.2 glm-4.7 kimi-k2.5 ornith nemotron glm-5.2 deepseek-v4-pro"
# (qwen3-235b serves via the sweep template — render separately.)

[ "${1:-}" = "--list" ] && { for k in $KEYS; do echo "$k"; done; exit 0; }
KEY="${1:?usage: run-rag-recollect.sh <model-key> | --list}"
R=$(recipe "$KEY") || { echo "unknown model key '$KEY' (see --list)" >&2; exit 1; }
read -r MANIFEST WORKERS TMO DEADLINE <<<"$R"

ACCT=$(aws sts get-caller-identity --query Account --output text) || exit 1
export BUCKET="kelsus-refarch-models-scale-$ACCT"

# refuse to stack serves: one campaign slot at a time
if [ "$(kubectl get job bench-quality -o jsonpath='{.status.active}' 2>/dev/null)" = "1" ]; then
  echo "ERROR: a bench-quality Job is still active — the previous model hasn't landed." >&2
  exit 1
fi

echo ">> [$KEY] belts: nightly-off + fresh $((DEADLINE/3600))h deadline"
kubectl apply -f infra/helm/gpu-nightly-off.yaml >/dev/null 2>&1
kubectl delete job gpu-deadline --ignore-not-found >/dev/null 2>&1
sed "s/21600/$DEADLINE/" infra/helm/gpu-deadline-job.yaml | kubectl apply -f - >/dev/null

echo ">> [$KEY] deploying $MANIFEST"
kubectl apply -f "$MANIFEST" >/dev/null || { echo "apply failed" >&2; exit 1; }
# Block VOLUNTARY Karpenter disruption of the serve (AMI drift replaced a node 40min
# into a bring-up, 2026-07-01). Spot reclaim is still possible; the Deployment
# self-heals and the eval Job retries (backoffLimit 2).
kubectl patch deploy vllm --type merge \
  -p '{"spec":{"template":{"metadata":{"annotations":{"karpenter.sh/do-not-disrupt":"true"}}}}}' >/dev/null
kubectl scale deploy/vllm --replicas=1 >/dev/null

echo ">> [$KEY] submitting RAG-only collect (gold v2, WORKERS=$WORKERS, timeout=${TMO}s)"
SKIP_EXTRACTION=1 SKIP_COMMERCIAL=1 WORKERS="$WORKERS" RAG_TIMEOUT="$TMO" N=0 QN=0 \
  bash bench/run-quality-incluster.sh >/dev/null || { echo "submit failed — scaling vllm to 0" >&2; kubectl scale deploy/vllm --replicas=0; exit 1; }
if [ "$(kubectl get job bench-quality -o jsonpath='{.status.active}' 2>/dev/null)" != "1" ]; then
  echo "ERROR: eval Job not active after submit — scaling vllm to 0" >&2
  kubectl scale deploy/vllm --replicas=0; exit 1
fi
echo ">> [$KEY] submitted; the Job waits for vLLM, collects, ships to S3, releases the GPU."
echo ">> record the results/quality/<ts>.json key against '$KEY' when it lands."
echo "RECOLLECT_HANDOFF_DONE $KEY"
