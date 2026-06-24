#!/usr/bin/env python3
"""Cost/latency load generator — runs IN-CLUSTER against the vLLM endpoint.

For each concurrency level: fire N streaming chat completions, measure
time-to-first-token and total time per request, and aggregate throughput
(completion tokens / wall-clock). Stdlib only, so the Job needs no pip install.

Emits the per-level summary as JSON between ===SUMMARY=== / ===END=== markers
(progress goes to stderr). cost-per-token is computed in postprocess.py from the
instance price, keeping this pure measurement.

Env: ENDPOINT, MODEL, CONCURRENCIES (csv), REQUESTS_PER_LEVEL?, MAX_TOKENS, PROMPT
"""
import json
import math
import os
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor

ENDPOINT = os.environ.get("ENDPOINT", "http://vllm:8000/v1")
MODEL = os.environ.get("MODEL", "local")
CONCURRENCIES = [int(x) for x in os.environ.get("CONCURRENCIES", "1,8,32,64").split(",")]
MAX_TOKENS = int(os.environ.get("MAX_TOKENS", "256"))
PROMPT = os.environ.get(
    "PROMPT",
    "Summarize the key responsibilities of a loan-servicing operations team, "
    "including payment processing, escrow, delinquency handling, and investor "
    "reporting. Write about 200 words.")


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def one_request():
    body = {"model": MODEL, "temperature": 0, "max_tokens": MAX_TOKENS,
            "stream": True, "stream_options": {"include_usage": True},
            "messages": [{"role": "user", "content": PROMPT}]}
    req = urllib.request.Request(
        f"{ENDPOINT}/chat/completions", data=json.dumps(body).encode(),
        headers={"content-type": "application/json"})
    t0 = time.perf_counter()
    ttft = None
    comp = 0
    with urllib.request.urlopen(req, timeout=300) as r:
        for raw in r:
            line = raw.decode("utf-8", "ignore").strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            chunk = json.loads(data)
            choices = chunk.get("choices") or []
            if choices and (choices[0].get("delta") or {}).get("content"):
                if ttft is None:
                    ttft = time.perf_counter() - t0
            if chunk.get("usage"):
                comp = chunk["usage"].get("completion_tokens", comp)
    return ttft, time.perf_counter() - t0, comp


def pct(sorted_vals, p):
    if not sorted_vals:
        return None
    i = min(len(sorted_vals) - 1, max(0, math.ceil(p / 100 * len(sorted_vals)) - 1))
    return round(sorted_vals[i], 1)


def run_level(concurrency):
    n = max(32, concurrency * 3)
    log(f"  level c={concurrency}: {n} requests ...")
    results, errors = [], 0
    start = time.perf_counter()
    with ThreadPoolExecutor(max_workers=concurrency) as ex:
        for f in [ex.submit(one_request) for _ in range(n)]:
            try:
                results.append(f.result())
            except Exception as e:  # noqa: BLE001
                errors += 1
                log(f"    request error: {e}")
    wall = time.perf_counter() - start
    ttfts = sorted(r[0] * 1000 for r in results if r[0] is not None)
    totals = sorted(r[1] * 1000 for r in results)
    toks = sum(r[2] for r in results)
    return {
        "concurrency": concurrency, "requests": len(results), "errors": errors,
        "ttft_ms": {"p50": pct(ttfts, 50), "p95": pct(ttfts, 95), "p99": pct(ttfts, 99)},
        "total_ms": {"p50": pct(totals, 50), "p95": pct(totals, 95), "p99": pct(totals, 99)},
        "completion_tokens": toks, "wall_s": round(wall, 2),
        "throughput_tok_s": round(toks / wall, 1) if wall > 0 else 0,
    }


def main():
    log(f"warmup against {ENDPOINT} (model={MODEL}) ...")
    for _ in range(3):
        try:
            one_request()
        except Exception as e:  # noqa: BLE001
            log(f"warmup error: {e}")
    levels = [run_level(c) for c in CONCURRENCIES]
    summary = {"model": MODEL, "endpoint": ENDPOINT, "max_tokens": MAX_TOKENS,
               "prompt_chars": len(PROMPT), "levels": levels}
    print("===SUMMARY===")
    print(json.dumps(summary))
    print("===END===")


if __name__ == "__main__":
    main()
