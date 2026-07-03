#!/usr/bin/env python3
"""Validate the v2 (context-aware) judge against the EXP-002 human anchor.

THE GATE for the RAG re-baseline: EXP-002 (PR#65) human-labeled 50 oracle-arm
answers — human 98.0% correct, Opus 98.4%, but the v1 judge marked only 65.2%,
wrongly rejecting 17/50 (0 the reverse). The v2 judge must close that gap
BEFORE any re-baseline verdicts are trusted. This script replays the anchored
items through judge(context=...) and reports agreement + the wrongful-rejection
count. Pass criteria (defaults): agreement >= 90% and wrongful rejections <= 2.

Inputs:
  --anchor     docs/benchmarks/exp-002-stage0/human_anchor.json (on main after
               PR#65; or `git show main:docs/.../human_anchor.json > /tmp/a.json`)
  --collected  the EXP-002 oracle-arm per-item file
               (s3://.../results/exp-002-stage0/oracle.collected.json or a local
               copy). Items are matched to anchor labels by question text.
  --corpus     optional data/corpus/seed/docs.jsonl — used to look up the gold
               passage by `source` when an item carries no context/passage field.

Needs the judge serving (JUDGE_URL/JUDGE_MODEL — the version-locked
Qwen2.5-VL-72B via infra/helm/vllm-judge-qwen72b.yaml). Exits non-zero on gate
failure, so it can gate a pipeline.
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(__file__))
from judge import judge  # noqa: E402


def load(path):
    if path.startswith("s3://"):
        with tempfile.NamedTemporaryFile(suffix=".json") as t:
            subprocess.run(["aws", "s3", "cp", path, t.name, "--only-show-errors"], check=True)
            return json.load(open(t.name))
    return json.load(open(path))


def norm(q):
    return " ".join(q.lower().split())


def find_items(data):
    """Accept the collected-file shapes in use: a bare list, {'rag': {'collected': []}},
    {'items': []}, or {'collected': []}."""
    if isinstance(data, list):
        return data
    for key in ("items", "collected"):
        if isinstance(data.get(key), list):
            return data[key]
    rag = data.get("rag") or {}
    if isinstance(rag.get("collected"), list):
        return rag["collected"]
    sys.exit("unrecognized collected-file shape")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--anchor", required=True)
    ap.add_argument("--collected", required=True)
    ap.add_argument("--corpus", default=None, help="docs.jsonl for passage lookup by source")
    ap.add_argument("--min-agreement", type=float, default=0.90)
    ap.add_argument("--max-wrongful-rejections", type=int, default=2)
    args = ap.parse_args()

    anchor = load(args.anchor)
    labels = {norm(l["question"]): bool(l["gold_label"]) for l in anchor["labels"]}
    items = find_items(load(args.collected))
    by_q = {}
    for it in items:
        q = it.get("question") or it.get("q") or ""
        by_q.setdefault(norm(q), it)

    corpus = {}
    if args.corpus:
        for line in open(args.corpus):
            if line.strip():
                d = json.loads(line)
                corpus[d.get("source", "")] = d.get("text", "")

    agree = wrongful_rej = wrongful_acc = skipped = 0
    mismatches = []
    for qn, human_correct in labels.items():
        it = by_q.get(qn)
        if it is None:
            skipped += 1
            print(f"  SKIP (no collected item): {qn[:80]}", file=sys.stderr)
            continue
        ctx = (it.get("context") or it.get("passage") or it.get("gold_passage")
               or corpus.get(it.get("source", "")) or None)
        if ctx is None:
            skipped += 1
            print(f"  SKIP (no context available): {qn[:80]}", file=sys.stderr)
            continue
        verdict = judge(it["question"], it.get("gold") or it.get("reference", ""),
                        it.get("answer", ""), context=ctx)
        j = bool(verdict["correct"])
        if j == human_correct:
            agree += 1
        elif human_correct and not j:
            wrongful_rej += 1
            mismatches.append(("WRONGFUL-REJECT", qn[:90], verdict.get("reason", "")[:120]))
        else:
            wrongful_acc += 1
            mismatches.append(("WRONGFUL-ACCEPT", qn[:90], verdict.get("reason", "")[:120]))

    judged = agree + wrongful_rej + wrongful_acc
    if not judged:
        sys.exit("nothing judged — check --collected matching and context availability")
    pct = agree / judged
    print(f"\n  v2 judge vs human anchor: agreement {agree}/{judged} = {pct:.1%}")
    print(f"  wrongful rejections: {wrongful_rej}  (v1 judge: 17/50)")
    print(f"  wrongful acceptances: {wrongful_acc}  |  skipped: {skipped}")
    for tag, q, reason in mismatches:
        print(f"    {tag}: {q}\n      judge: {reason}")

    ok = pct >= args.min_agreement and wrongful_rej <= args.max_wrongful_rejections
    print(f"\n  GATE: {'PASS' if ok else 'FAIL'} "
          f"(need agreement >= {args.min_agreement:.0%} and wrongful rejections <= "
          f"{args.max_wrongful_rejections})")
    sys.exit(0 if ok else 2)


if __name__ == "__main__":
    main()
