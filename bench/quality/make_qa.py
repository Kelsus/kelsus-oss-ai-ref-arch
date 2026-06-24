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
OUT = Path(__file__).parent / "rag_gold.json"


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
           "Do not ask about anything not stated in the passage.")
VERIFY_SYS = ("You verify a QA pair against a passage. Return JSON "
              "{\"ok\": true|false}. ok=true only if the question is answerable "
              "from the passage ALONE and the answer is correct and supported.")


def main():
    docs = [json.loads(l) for l in open(CORPUS) if l.strip()]
    docs = [d for d in docs if len(d.get("text", "")) >= 250]   # substantive only
    qa = []
    for i, d in enumerate(docs):
        if len(qa) >= N:
            break
        passage = d["text"]
        try:
            gen = llm_json(GEN_SYS, f"PASSAGE:\n{passage}")
            q, a = gen.get("question", "").strip(), gen.get("answer", "").strip()
            if not q or not a:
                continue
            v = llm_json(VERIFY_SYS,
                         f"PASSAGE:\n{passage}\n\nQ: {q}\nA: {a}\n\nVerify:")
            if not v.get("ok"):
                continue
            qa.append({"question": q, "answer": a,
                       "source": d.get("source", ""), "title": d.get("title", "")})
        except Exception as e:  # noqa: BLE001
            print(f"  skip doc {i}: {e}", file=sys.stderr)
        if len(qa) % 25 == 0 and qa:
            print(f"  {len(qa)} verified QA pairs ...", file=sys.stderr)
    json.dump(qa, open(OUT, "w"), indent=2)
    print(f"wrote {len(qa)} verified QA pairs -> {OUT}")


if __name__ == "__main__":
    main()
