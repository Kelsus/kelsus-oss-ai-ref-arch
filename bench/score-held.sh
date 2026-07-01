#!/usr/bin/env bash
# Score the CURRENTLY-SERVED model's extraction WITHOUT releasing the GPU — for the
# H200 re-run campaign where one scarce 8xH200 box is held and many models are swapped
# through it back-to-back. Unlike bench/run-quality-incluster.sh (which traps EXIT to
# scale vllm->0), this drives score.py locally against the in-cluster gateway via a
# port-forward and NEVER touches the vllm deployment. The node stays held for the next
# model.
#
# Usage:  bench/score-held.sh <result-name> [TIERS]
#   result-name : e.g. deepseek-v4-pro  (S3 -> results/quality/<name>-<UTCts>.json)
#   TIERS       : default "clean-digital" (text models). Pass "" for all tiers (vision).
set -uo pipefail
cd "$(dirname "$0")/.."
NAME="${1:?usage: score-held.sh <result-name> [TIERS]}"
TIERS_IN="${2-clean-digital}"
export AWS_PROFILE=kelsus-dev KUBECONFIG=/tmp/kubeconfig-scale AWS_REGION=us-west-2
ACCT=$(aws sts get-caller-identity --query Account --output text)
BUCKET="kelsus-refarch-models-scale-$ACCT"
TS=$(date -u +%Y%m%dT%H%M%SZ)
OUT="/tmp/v4res/${NAME}-${TS}.json"; mkdir -p /tmp/v4res

# vision models score commercial too; text models skip it
SKIP_COMM=1; [ -z "$TIERS_IN" ] && SKIP_COMM=
kubectl port-forward svc/gateway 18088:8000 >/tmp/pf-gw.log 2>&1 & PF=$!
trap 'kill $PF 2>/dev/null' EXIT
sleep 6

echo ">> scoring $NAME (TIERS='${TIERS_IN:-all}') against held serve — no GPU release"
GATEWAY=http://localhost:18088 \
  SKIP_RAG=1 SKIP_COMMERCIAL=$SKIP_COMM TIERS="$TIERS_IN" \
  WORKERS=2 EXTRACT_TIMEOUT=1200 \
  python3 bench/quality/score.py 2>/tmp/score-err.log \
  | awk '/===QUALITY===/{f=1;next} /===END===/{f=0} f' > "$OUT"

if [ -s "$OUT" ] && python3 -c "import json;json.load(open('$OUT'))" 2>/dev/null; then
  aws s3 cp "$OUT" "s3://$BUCKET/results/quality/${NAME}-${TS}.json" --only-show-errors
  python3 - "$OUT" "$NAME" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); ext=d.get("extraction",{})
ct=(ext.get("tiers") or {}).get("clean-digital",{})
pf=ct.get("per_field",{})
print(f"  {sys.argv[2]}: clean-digital F1={ext.get('headline_f1_pct')}  provider_npi={pf.get('provider_npi')}  patient_name={pf.get('patient_name')}")
print(f"  -> {sys.argv[1]} (+ S3)")
PY
else
  echo "  !! score failed for $NAME — see /tmp/score-err.log"; tail -5 /tmp/score-err.log
fi