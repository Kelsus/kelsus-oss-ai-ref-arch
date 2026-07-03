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
import datetime
import json
import os
import subprocess
import sys
import tempfile
import urllib.request
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from judge import judge          # noqa: E402  (uses JUDGE_URL/JUDGE_MODEL env)
from stats import wilson_ci      # noqa: E402

WORKERS = int(os.environ.get("WORKERS", "16"))
MIN_COMPLETE = float(os.environ.get("MIN_COMPLETE", "0.8"))  # below this judged fraction => refuse to write


def _judge_provenance():
    """Identify the ACTUAL judge deployment, not just 'local'. SE-22: a judge-stack
    change silently shifted every score 6-12 pts, and the 29 v1 artifacts spanned
    >=5 judge deployments recorded only as {"model": "local"} — cross-pass
    comparability rested on an unverifiable claim (2026-07-01 review)."""
    base = (os.environ.get("JUDGE_URL") or "").rstrip("/")
    prov = {"url": os.environ.get("JUDGE_URL"), "model": os.environ.get("JUDGE_MODEL"),
            "judged_at_utc": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
            "endpoint_model_id": None, "vllm_version": None}
    try:  # vLLM /v1/models: the served model id
        with urllib.request.urlopen(f"{base}/models", timeout=10) as r:
            prov["endpoint_model_id"] = (json.loads(r.read()).get("data") or [{}])[0].get("id")
    except Exception:  # noqa: BLE001 — best-effort; absence is itself recorded
        pass
    try:  # vLLM /version lives at the root, not under /v1
        root = base[:-3] if base.endswith("/v1") else base
        with urllib.request.urlopen(f"{root}/version", timeout=10) as r:
            prov["vllm_version"] = json.loads(r.read()).get("version")
    except Exception:  # noqa: BLE001
        pass
    return prov


def load(path):
    if path.startswith("s3://"):
        with tempfile.NamedTemporaryFile(suffix=".json") as t:
            subprocess.run(["aws", "s3", "cp", path, t.name, "--only-show-errors"],
                           check=True)
            return json.load(open(t.name))
    return json.load(open(path))


def judge_one(item):
    if item.get("error"):  # the CANDIDATE never answered (collection-time failure):
        return 0           # scored incorrect without asking the judge (score.py policy)
    try:
        # context present -> v2 (context-aware) rubric; absent -> v1 verbatim.
        # The judged.json records context coverage so a mixed set is visible.
        return 1 if judge(item["question"], item["gold"], item["answer"],
                          context=item.get("context"))["correct"] else 0
    except Exception as e:  # noqa: BLE001
        print(f"  judge error: {e}", file=sys.stderr)
        return None


def main():
    rows = []
    prov = _judge_provenance()
    for arg in sys.argv[1:]:
        name, _, path = arg.partition("=")
        data = load(path)
        collected = (data.get("rag") or {}).get("collected") or []
        if not collected:
            print(f"  {name}: no collected answers (rag block judged inline?) — skipping")
            continue
        with ThreadPoolExecutor(WORKERS) as ex:
            verdicts = list(ex.map(judge_one, collected))
        judge_errs = sum(1 for x in verdicts if x is None)
        v = [x for x in verdicts if x is not None]
        # Completeness gate — the one this pass never had: an aborted n=2 run once
        # printed 0.0% into the ranking table and wrote a judged.json beside the
        # authoritative ones (2026-07-01 review). Refuse to write a verdict when
        # judge errors ate too much of the set.
        if len(collected) >= 10 and len(v) * 100 < round(MIN_COMPLETE * 100) * len(collected):
            print(f"  {name}: INVALID — judged {len(v)}/{len(collected)} "
                  f"(judge errors: {judge_errs}); NOT writing {name}.judged.json")
            continue
        n, c = len(v), sum(v)
        lo, hi = wilson_ci(c, n)
        rows.append((name, round(c / n * 100, 1) if n else 0.0,
                     round(lo * 100, 1), round(hi * 100, 1), n))
        out = os.path.join(os.path.dirname(__file__), f"{name}.judged.json")
        with_ctx = sum(1 for it in collected if it.get("context"))
        json.dump({"model": name, "accuracy_pct": rows[-1][1],
                   "ci_pct": [rows[-1][2], rows[-1][3]], "n": n,
                   "n_collected": len(collected), "judge_errors": judge_errs,
                   "candidate_errors": sum(1 for it in collected if it.get("error")),
                   "rubric": ("v2-context" if with_ctx == len(collected)
                              else "v1-blind" if with_ctx == 0
                              else f"MIXED({with_ctx}/{len(collected)} with context)"),
                   "source": path,
                   "judge": prov},
                  open(out, "w"), indent=2)
    print(f"\n  {'model':24} {'RAG acc':>8}  {'95% CI':>16} {'n':>5}   (single fixed judge)")
    for name, acc, lo, hi, n in sorted(rows, key=lambda r: -r[1]):
        print(f"  {name:24} {acc:>7}%  [{lo:>5}, {hi:>5}] {n:>5}")


if __name__ == "__main__":
    main()
