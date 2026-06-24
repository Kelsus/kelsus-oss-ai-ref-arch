#!/usr/bin/env python3
"""Render the vLLM sweep template to stdout from env vars.

  MODEL=... TP=8 GPUS=8 MAXLEN=16384 CACHE=250Gi EXTRA="--flag1 --flag2" \
    python3 bench/render-vllm.py | kubectl apply -f -

Standalone file (no shell heredoc): a heredoc inside the sweep loop silently
produced empty output in one environment and the apply ate it — a template
renderer is too important to live inside string-escaping (see sweep history).
"""
import os
import sys

TMPL = os.path.join(os.path.dirname(__file__), "..", "infra", "helm", "vllm-sweep.yaml.tmpl")

s = open(TMPL).read()
extra = "".join(f"\n            - {a}" for a in os.environ.get("EXTRA", "").split())
for k in ("MODEL", "TP", "GPUS", "MAXLEN", "CACHE"):
    v = os.environ.get(k)
    if not v:
        sys.exit(f"missing required env: {k}")
    s = s.replace(f"__{k}__", v)
out = s.replace("__EXTRA_ARGS_YAML__", extra)
if "__" in out.replace("___", ""):  # any placeholder left un-substituted?
    sys.exit("unsubstituted placeholder remains — refusing to emit")
try:  # the comment-substitution bug emitted structurally-broken YAML: validate
    import yaml
    docs = [d for d in yaml.safe_load_all(out)]
    assert all(isinstance(d, dict) and d.get("kind") for d in docs), "non-object doc"
except ImportError:
    pass
except Exception as e:
    sys.exit(f"rendered YAML invalid: {e}")
print(out)
