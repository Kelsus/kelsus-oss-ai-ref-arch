#!/usr/bin/env bash
# Durable run status in S3 — survives laptop sleep, watcher death, and SSO churn.
# State lives in the cluster's results bucket, not in a laptop-side process, so
# "where are we?" is always answerable in one read (the reporting-reliability fix).
#
#   bench/status.sh set "message"   # append timestamped line + refresh latest
#   bench/status.sh get             # print the recent status history
#
# BUCKET/AWS_REGION overridable; defaults to the scale (GPU-run) bucket.
set -uo pipefail
export AWS_PROFILE="${AWS_PROFILE:-kelsus-dev}" AWS_REGION="${AWS_REGION:-us-west-2}"
ACCT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
BUCKET="${BUCKET:-kelsus-refarch-models-scale-$ACCT}"
KEY="results/status/latest.txt"
URI="s3://$BUCKET/$KEY"

case "${1:-get}" in
  set)
    LINE="$(date -u +%Y-%m-%dT%H:%M:%SZ)  ${2:-}"
    aws s3 cp "$URI" /tmp/_refarch_status.txt --only-show-errors 2>/dev/null || : > /tmp/_refarch_status.txt
    echo "$LINE" >> /tmp/_refarch_status.txt
    tail -100 /tmp/_refarch_status.txt > /tmp/_refarch_status2.txt && mv /tmp/_refarch_status2.txt /tmp/_refarch_status.txt
    aws s3 cp /tmp/_refarch_status.txt "$URI" --only-show-errors >/dev/null
    echo "$LINE" ;;
  get)
    aws s3 cp "$URI" - --only-show-errors 2>/dev/null | tail -20 || echo "(no status recorded yet)" ;;
  *)
    echo "usage: status.sh {set <msg>|get}" >&2; exit 2 ;;
esac
