#!/usr/bin/env python3
"""Merge load-test results with instance pricing -> summary.json + results.csv.

  python3 postprocess.py <raw.log> <config.json> <out_dir>

Reads the JSON the loadgen printed between ===SUMMARY===/===END=== markers,
computes $/M-tokens from the instance hourly price and measured peak throughput
(and at 30/60/90% utilization, per the Index methodology), writes the merged
summary + a per-level CSV, and prints a readable table.
"""
import csv
import json
import re
import sys


def extract_summary(log_text):
    m = re.search(r"===SUMMARY===\s*(\{.*?\})\s*===END===", log_text, re.S)
    if not m:
        raise SystemExit("no summary block found in log (job may have failed)")
    return json.loads(m.group(1))


def cost_per_mtok(hourly, tok_s):
    return round(hourly / (tok_s * 3600) * 1e6, 4) if tok_s else None


def main():
    raw, cfg_path, out = sys.argv[1], sys.argv[2], sys.argv[3]
    summary = extract_summary(open(raw).read())
    cfg = json.load(open(cfg_path))
    hourly = cfg["instance_hourly_usd"]

    peak = max((l["throughput_tok_s"] for l in summary["levels"]), default=0)
    summary["config"] = cfg
    summary["cost"] = {
        "peak_throughput_tok_s": peak,
        "usd_per_million_output_tokens": {
            "at_peak": cost_per_mtok(hourly, peak),
            "at_90pct_util": cost_per_mtok(hourly, peak * 0.9),
            "at_60pct_util": cost_per_mtok(hourly, peak * 0.6),
            "at_30pct_util": cost_per_mtok(hourly, peak * 0.3),
        },
    }

    with open(f"{out}/summary.json", "w") as f:
        json.dump(summary, f, indent=2)
    with open(f"{out}/results.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["concurrency", "requests", "errors",
                    "ttft_p50_ms", "ttft_p95_ms", "ttft_p99_ms",
                    "total_p50_ms", "total_p95_ms", "total_p99_ms",
                    "throughput_tok_s"])
        for l in summary["levels"]:
            w.writerow([l["concurrency"], l["requests"], l["errors"],
                        l["ttft_ms"]["p50"], l["ttft_ms"]["p95"], l["ttft_ms"]["p99"],
                        l["total_ms"]["p50"], l["total_ms"]["p95"], l["total_ms"]["p99"],
                        l["throughput_tok_s"]])

    print(f"\n  model: {cfg['model_id']}  on {cfg['instance_type']} ({cfg['gpu']})")
    print(f"  {'conc':>4} {'TTFT p50/p95/p99 (ms)':>26} {'total p95 (ms)':>15} {'tok/s':>8} {'err':>4}")
    for l in summary["levels"]:
        t = l["ttft_ms"]
        print(f"  {l['concurrency']:>4} "
              f"{str(t['p50'])+'/'+str(t['p95'])+'/'+str(t['p99']):>26} "
              f"{str(l['total_ms']['p95']):>15} {l['throughput_tok_s']:>8} {l['errors']:>4}")
    c = summary["cost"]["usd_per_million_output_tokens"]
    print(f"\n  peak throughput: {peak} tok/s")
    print(f"  $/M output tokens — peak {c['at_peak']} | 90% {c['at_90pct_util']} | "
          f"60% {c['at_60pct_util']} | 30% {c['at_30pct_util']}")
    print(f"  (instance ${hourly}/hr — {cfg['price_basis']})")


if __name__ == "__main__":
    main()
