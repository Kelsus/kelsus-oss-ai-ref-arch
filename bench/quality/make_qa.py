#!/usr/bin/env python3
"""Generate a passage-grounded RAG QA set from the corpus (one-time, LLM pass).

For N sampled corpus passages, ask the model to write a specific question
answerable ONLY from that passage plus the correct answer, then run a second
verification pass and keep only the ones confirmed answerable+correct. Output is
the eval set App 2 / the sweep score against.

Needs the LLM endpoint up (run during a GPU window — e.g. start of the
validation run). Endpoints via env; defaults assume a local port-forward.

  VLLM_URL  (default http://127.0.0.1:8000/v1)   MODEL (default local)
  N         how many passages to attempt (default 500)

  python3 make_qa.py            # -> bench/quality/rag_gold.json
"""
import json
import os
import re
import sys
import urllib.request
from pathlib import Path

VLLM_URL = os.environ.get("VLLM_URL", "http://127.0.0.1:8000/v1")
MODEL = os.environ.get("MODEL", "local")
N = int(os.environ.get("N", sys.argv[1] if len(sys.argv) > 1 else "500"))

ROOT = Path(__file__).resolve().parents[2]
CORPUS = ROOT / "data" / "corpus" / "seed" / "docs.jsonl"
# NOT rag_gold.json: the shipped v1/v2 sets are frozen benchmark artifacts. A fresh
# generation writes to its own file and gets promoted deliberately, never by accident.
OUT = Path(os.environ.get("QA_OUT", Path(__file__).parent / "rag_gold_generated.json"))


def _post(payload, timeout=120):
    req = urllib.request.Request(
        f"{VLLM_URL}/chat/completions", data=json.dumps(payload).encode(),
        headers={"content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())["choices"][0]["message"]["content"]


def llm_json(system, user):
    out = _post({"model": MODEL, "temperature": 0, "max_tokens": 400,
                 "response_format": {"type": "json_object"},
                 "messages": [{"role": "system", "content": system},
                              {"role": "user", "content": user}]})
    m = re.search(r"\{.*\}", out, re.S)
    return json.loads(m.group(0)) if m else {}


GEN_SYS = ("You write evaluation questions for a financial-regulation RAG system. "
           "Given ONE passage, produce a JSON object {\"question\":..,\"answer\":..} "
           "where the question is specific and answerable using ONLY this passage, "
           "and the answer is concise (<=2 sentences) and fully supported by it. "
           "Do not ask about anything not stated in the passage. "
           # v2 lesson (2026-07-01 review): per-passage generation with no corpus
           # awareness produced 26 duplicated questions and ~50 entity-free ones
           # ("What is the purpose of the notice?") that are unanswerable against a
           # corpus of thousands of documents.
           "CRITICAL: the question must IDENTIFY its document — name the specific "
           "rule/report/act, agency + subject, or the document title — so that a "
           "reader of a large corpus knows exactly which document is meant. Never "
           "refer to 'the notice', 'the rule', 'the proposal', or 'the passage' "
           "without naming it.")
VERIFY_SYS = ("You verify a QA pair against a passage. Return JSON "
              "{\"ok\": true|false}. ok=true only if the question is answerable "
              "from the passage ALONE and the answer is correct and supported.")


def _generator_identity():
    """Record WHICH model wrote the gold (2026-07-01 review: v1 recorded nothing,
    so a family-match advantage between generator and any candidate is unauditable)."""
    import datetime
    ident = {"endpoint": VLLM_URL, "model_env": MODEL,
             "generated_at_utc": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
             "endpoint_model_id": None}
    try:
        req = urllib.request.Request(f"{VLLM_URL}/models")
        with urllib.request.urlopen(req, timeout=10) as r:
            ident["endpoint_model_id"] = (json.loads(r.read()).get("data") or [{}])[0].get("id")
    except Exception:  # noqa: BLE001 — best-effort; absence is itself recorded
        pass
    return ident


def main():
    docs = [json.loads(l) for l in open(CORPUS) if l.strip()]
    docs = [d for d in docs if len(d.get("text", "")) >= 250]   # substantive only
    qa, seen, dropped_dup = [], set(), 0
    for i, d in enumerate(docs):
        if len(qa) >= N:
            break
        passage = d["text"]
        try:
            gen = llm_json(GEN_SYS, f"PASSAGE:\n{passage}")
            q, a = gen.get("question", "").strip(), gen.get("answer", "").strip()
            if not q or not a:
                continue
            # CORPUS-LEVEL uniqueness — the check v1 lacked. Per-passage verification
            # can never catch two passages yielding the same question with different
            # answers; a deterministic candidate is then wrong on all-but-one copy.
            if q.lower() in seen:
                dropped_dup += 1
                continue
            v = llm_json(VERIFY_SYS,
                         f"PASSAGE:\n{passage}\n\nQ: {q}\nA: {a}\n\nVerify:")
            if not v.get("ok"):
                continue
            seen.add(q.lower())
            qa.append({"question": q, "answer": a,
                       "source": d.get("source", ""), "title": d.get("title", "")})
        except Exception as e:  # noqa: BLE001
            print(f"  skip doc {i}: {e}", file=sys.stderr)
        if len(qa) % 25 == 0 and qa:
            print(f"  {len(qa)} verified QA pairs ...", file=sys.stderr)
    meta = {"generator": _generator_identity(), "n": len(qa),
            "dropped_duplicate_questions": dropped_dup,
            "prompt": "GEN_SYS with the document-identification requirement (v2)"}
    json.dump({"_meta": meta, "answerable": qa}, open(OUT, "w"), indent=2)
    print(f"wrote {len(qa)} verified QA pairs (+{dropped_dup} dup-dropped) -> {OUT}")


if __name__ == "__main__":
    main()
