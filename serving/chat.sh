#!/usr/bin/env bash
# Send a prompt to the in-VPC vLLM endpoint from your laptop.
# Opens a temporary kubectl port-forward to the internal service, sends one
# chat completion, prints the reply, and tears the tunnel down on exit.
#
# Usage:
#   ./serving/chat.sh "What are three risks of self-hosting an LLM for a bank?"
#   make chat PROMPT="..."
set -euo pipefail

PROMPT="${*:-In one sentence, what is sovereign AI?}"
NS="${NS:-default}"
PORT="${LOCAL_PORT:-8000}"
export AWS_PROFILE="${AWS_PROFILE:-kelsus-dev}" AWS_REGION="${AWS_REGION:-us-east-1}"

command -v kubectl >/dev/null || { echo "kubectl not found"; exit 1; }

# Clear any stale tunnel from a previous run, then bind IPv4 explicitly
# (kubectl's default [::1] binding races with curl's localhost resolution).
pkill -f "kubectl.*port-forward.*svc/vllm" 2>/dev/null || true
echo "==> opening tunnel to the internal vLLM service (127.0.0.1:${PORT}) ..."
kubectl -n "$NS" port-forward --address 127.0.0.1 svc/vllm "${PORT}:8000" >/tmp/vllm-pf.log 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT

# Wait for the tunnel + server health (no sleep loop; curl retries on refusal).
if ! curl -sf --retry 40 --retry-delay 1 --retry-connrefused \
     "http://127.0.0.1:${PORT}/health" >/dev/null; then
  echo "ERROR: vLLM not reachable. tunnel log:"; cat /tmp/vllm-pf.log
  echo "Is the pod Ready?  kubectl get pods -l app=vllm"
  exit 1
fi

BODY=$(python3 - "$PROMPT" <<'PY'
import json, sys
print(json.dumps({
    "model": "local",
    "messages": [{"role": "user", "content": sys.argv[1]}],
    "max_tokens": 512,
    "temperature": 0.7,
}))
PY
)

echo "==> you: ${PROMPT}"
echo "==> model:"
RESP=$(curl -s --max-time 180 --retry 2 "http://127.0.0.1:${PORT}/v1/chat/completions" \
  -H 'content-type: application/json' -d "$BODY")
if [ -z "$RESP" ]; then
  echo "ERROR: empty response. tunnel log:"; cat /tmp/vllm-pf.log; exit 1
fi
printf '%s' "$RESP" | python3 -c 'import json,sys
d=json.load(sys.stdin)
print("\n"+d["choices"][0]["message"]["content"]+"\n")
u=d.get("usage",{})
print("[%s prompt + %s completion tokens]" % (u.get("prompt_tokens"), u.get("completion_tokens")))'
