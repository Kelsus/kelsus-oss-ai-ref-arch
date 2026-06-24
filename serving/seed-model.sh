#!/usr/bin/env bash
# Pull open-weight model weights ONCE into the in-account S3 bucket.
# This is the only step that reaches the public internet, and it is a build-time
# operation — never on the serving path (ADR-0001). vLLM then loads from S3.
set -euo pipefail

MODEL="${1:?usage: seed-model.sh <hf-model-id> [profile] [region]}"
PROFILE="${2:-kelsus-dev}"
REGION="${3:-us-east-1}"

ACCOUNT="$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text)"
BUCKET="kelsus-refarch-models-dev-${ACCOUNT}"
PREFIX="$(echo "$MODEL" | tr '/' '_')"
DEST="s3://${BUCKET}/${PREFIX}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

command -v aws >/dev/null || { echo "aws CLI required"; exit 1; }
python3 -c "import huggingface_hub" 2>/dev/null || pip install -q huggingface_hub

echo "==> Downloading $MODEL (build-time egress only) -> $TMP"
python3 -m huggingface_hub download "$MODEL" \
  --local-dir "$TMP" \
  --exclude "*.pth" "*.bin" "original/*"   # prefer safetensors

echo "==> Syncing to $DEST (in-account, KMS-encrypted at rest)"
aws s3 sync "$TMP" "$DEST" --profile "$PROFILE" --region "$REGION" --only-show-errors

echo "==> Done. Point vLLM at: $DEST"
