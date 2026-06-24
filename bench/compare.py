#!/usr/bin/env python3
"""Build a model-comparison table from a sweep directory of summary.json files.

  python3 compare.py bench/reports/sweeps/<ts>
"""
import json
import os
import sys


def main():
    sweep = sys.argv[1]
    rows = []
    for f in sorted(os.listdir(sweep)):
        if not f.endswith(".json"):
            continue
        d = json.load(open(os.path.join(sweep, f)))
        model = f[:-5].replace("_", "/")
        levels = d.get("levels", [])
        peak = (d.get("cost", {}).get("peak_throughput_tok_s")
                or max((l["throughput_tok_s"] for l in levels), default=0))
        c64 = next((l for l in levels if l["concurrency"] == 64),
                   levels[-1] if levels else {"ttft_ms": {"p99": None}})
        cost = d.get("cost", {}).get("usd_per_million_output_tokens", {}).get("at_peak")
        rows.append((model, peak, c64["ttft_ms"]["p99"], cost))
    rows.sort(key=lambda r: -(r[1] or 0))

    print("# Model sweep — cost/latency (same instance, same workload)\n")
    print("| model | peak tok/s | TTFT p99 @64 (ms) | $/M out tok (peak) |")
    print("|---|---:|---:|---:|")
    for m, p, t, c in rows:
        print(f"| {m} | {p} | {t} | {c} |")
    print("\n_No single composite score — pick per your workload's "
          "latency vs throughput vs cost priorities (and, separately, the "
          "quality numbers from the RAG/extraction runs)._")


if __name__ == "__main__":
    main()
