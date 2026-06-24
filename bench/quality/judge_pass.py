#!/usr/bin/env python3
"""Fixed-judge pass: judge collected RAG answers from one or more sweep runs
with a SINGLE judge model, so scores are comparable across candidates (kills
the self-judge confound demonstrated in the 7B-vs-72B validation).

Usage:
  JUDGE_URL=http://127.0.0.1:8000/v1 JUDGE_MODEL=local \
    python3 judge_pass.py model1=path/or/s3://...json model2=s3://...json

Each input is a quality-result JSON whose rag block contains
{"collected": [{question, gold, answer}, ...]}. Prints a comparison table and
writes <name>.judged.json beside this script.
"""
import json
import os
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from judge import judge          # noqa: E402  (uses JUDGE_URL/JUDGE_MODEL env)
from stats import wilson_ci      # noqa: E402

WORKERS = int(os.environ.get("WORKERS", "16"))


def load(path):
    if path.startswith("s3://"):
        with tempfile.NamedTemporaryFile(suffix=".json") as t:
            subprocess.run(["aws", "s3", "cp", path, t.name, "--only-show-errors"],
                           check=True)
            return json.load(open(t.name))
    return json.load(open(path))


def judge_one(item):
    try:
        return 1 if judge(item["question"], item["gold"], item["answer"])["correct"] else 0
    except Exception as e:  # noqa: BLE001
        print(f"  judge error: {e}", file=sys.stderr)
        return None


def main():
    rows = []
    for arg in sys.argv[1:]:
        name, _, path = arg.partition("=")
        data = load(path)
        collected = (data.get("rag") or {}).get("collected") or []
        if not collected:
            print(f"  {name}: no collected answers (rag block judged inline?) — skipping")
            continue
        with ThreadPoolExecutor(WORKERS) as ex:
            v = [x for x in ex.map(judge_one, collected) if x is not None]
        n, c = len(v), sum(v)
        lo, hi = wilson_ci(c, n)
        rows.append((name, round(c / n * 100, 1) if n else 0.0,
                     round(lo * 100, 1), round(hi * 100, 1), n))
        out = os.path.join(os.path.dirname(__file__), f"{name}.judged.json")
        json.dump({"model": name, "accuracy_pct": rows[-1][1],
                   "ci_pct": [rows[-1][2], rows[-1][3]], "n": n,
                   "judge": {"url": os.environ.get("JUDGE_URL"),
                             "model": os.environ.get("JUDGE_MODEL")}},
                  open(out, "w"), indent=2)
    print(f"\n  {'model':24} {'RAG acc':>8}  {'95% CI':>16} {'n':>5}   (single fixed judge)")
    for name, acc, lo, hi, n in sorted(rows, key=lambda r: -r[1]):
        print(f"  {name:24} {acc:>7}%  [{lo:>5}, {hi:>5}] {n:>5}")


if __name__ == "__main__":
    main()
