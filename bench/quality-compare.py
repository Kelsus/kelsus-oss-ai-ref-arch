#!/usr/bin/env python3
"""Build a quality-comparison table from a quality-sweep directory."""
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
        rows.append((d.get("model", f[:-5]),
                     d.get("extraction_f1_pct"),
                     d.get("rag_fact_coverage_pct"),
                     d.get("rag_grounding_pct")))
    rows.sort(key=lambda r: -(r[1] or 0))

    print("# Model sweep — quality (App 1 extraction + App 2 RAG)\n")
    print("Fixed retrieval (same embeddings + reranker); only the generation model varies.\n")
    print("| model | extraction F1 | RAG fact coverage | RAG grounding |")
    print("|---|---:|---:|---:|")
    for m, e, fc, g in rows:
        print(f"| {m} | {e}% | {fc}% | {g}% |")
    print("\n_Pair with the cost/latency sweep for the full picture — "
          "cheapest/fastest ≠ best when quality on the target workload matters. "
          "RAG metrics here are a directional proxy; full LLM-judge eval is Index scope._")


if __name__ == "__main__":
    main()
