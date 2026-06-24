#!/usr/bin/env bash
# Call the in-cluster gateway from your laptop via a temporary tunnel.
#   ./call.sh ask "What has the CFPB proposed about overdraft fees?"
#   ./call.sh extract data/synthea/output/forms/<id>.pdf
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-kelsus-dev}" AWS_REGION="${AWS_REGION:-us-east-1}"
P='kubectl.*port-forward.*svc/gateway'

pkill -f "$P" 2>/dev/null || true
kubectl port-forward --address 127.0.0.1 svc/gateway 8088:8000 >/tmp/pf-gw.log 2>&1 &
trap 'pkill -f "$P" 2>/dev/null || true' EXIT
curl -sf --retry 40 --retry-delay 1 --retry-connrefused http://127.0.0.1:8088/health >/dev/null

case "${1:-}" in
  ask)
    body=$(python3 -c 'import json,sys; print(json.dumps({"q": sys.argv[1]}))' "${2:-}")
    curl -s -X POST http://127.0.0.1:8088/rag/query -H 'content-type: application/json' -d "$body" \
    | python3 -c 'import json,sys
d=json.load(sys.stdin)
print("\n"+d["answer"]+"\n\nSOURCES:")
for c in d["citations"]:
    print("  ["+str(c["n"])+"] "+c["title"][:60]+"  ("+str(c["score"])+")\n      "+c["source"])'
    ;;
  extract)
    curl -s -F "file=@${2:?usage: call.sh extract <pdf>}" http://127.0.0.1:8088/extract \
    | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["fields"], indent=2))'
    ;;
  *) echo "usage: call.sh {ask <question> | extract <pdf>}"; exit 1 ;;
esac
