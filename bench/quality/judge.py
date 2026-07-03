#!/usr/bin/env python3
"""LLM-as-judge for RAG answer quality.

v2 (context-aware) rubric, 2026-07-01: EXP-002 (PR#65) human-anchored the v1
judge and found it wrongly rejected 17/50 answers a human marked correct (0 the
reverse) — the v1 rubric's "does not add unsupported claims" clause, applied by
a judge that NEVER SAW the retrieved passage, rejected correct grounded
elaboration as fabrication. v2 shows the judge the CONTEXT the candidate
actually saw and instructs it that context-supported detail is not an error.

judge(question, reference, candidate, context=None):
  - context given  -> v2 rubric (the re-baseline path; collected items carry it)
  - context absent -> the verbatim v1 rubric, for reproducing v1 numbers only.
The returned dict includes "rubric" so every verdict is attributable.

  JUDGE_URL  (default = VLLM_URL or http://127.0.0.1:8000/v1)
  JUDGE_MODEL (default 'local')
"""
import json
import os
import re
import urllib.request

JUDGE_URL = os.environ.get("JUDGE_URL", os.environ.get("VLLM_URL", "http://127.0.0.1:8000/v1"))
JUDGE_MODEL = os.environ.get("JUDGE_MODEL", "local")
_CTX_CAP = int(os.environ.get("JUDGE_CONTEXT_CAP", "16000"))  # chars; keeps within the judge's 8K window

_SYS_V1 = ("You are a strict grader for a financial-regulation QA system. Compare the "
           "CANDIDATE answer to the REFERENCE answer for the QUESTION. Return JSON "
           "{\"correct\": true|false, \"score\": 0-100, \"reason\": \"...\"}. "
           "correct=true only if the candidate is factually consistent with the "
           "reference and does not add unsupported claims. Brevity is fine.")

_SYS_V2 = ("You grade one answer from a financial-regulation RAG system. You receive "
           "the QUESTION, a terse REFERENCE answer (the ground truth), the CONTEXT "
           "passages the system retrieved, and the CANDIDATE answer. Return JSON "
           "{\"correct\": true|false, \"score\": 0-100, \"reason\": \"...\"}.\n"
           "correct=true when the CANDIDATE conveys the substance of the REFERENCE, "
           "or an equivalent correct answer that the CONTEXT clearly supports. Detail "
           "beyond the REFERENCE is NOT an error when the CONTEXT supports it — do not "
           "penalize grounded elaboration, length, style, or bracketed citations.\n"
           "correct=false only when the CANDIDATE (a) contradicts the REFERENCE or the "
           "CONTEXT, (b) does not actually answer the QUESTION, (c) declines to answer "
           "although the REFERENCE answers it, or (d) asserts specific factual claims "
           "found in neither the REFERENCE nor the CONTEXT.")


def judge(question, reference, candidate, context=None, timeout=60):
    if context:
        rubric = "v2-context"
        user = (f"QUESTION: {question}\n\nREFERENCE: {reference}\n\n"
                f"CONTEXT:\n{context[:_CTX_CAP]}\n\nCANDIDATE: {candidate}\n\nGrade:")
        sys_prompt = _SYS_V2
    else:
        rubric = "v1-blind"
        user = (f"QUESTION: {question}\n\nREFERENCE: {reference}\n\n"
                f"CANDIDATE: {candidate}\n\nGrade:")
        sys_prompt = _SYS_V1
    body = {"model": JUDGE_MODEL, "temperature": 0, "max_tokens": 200,
            "response_format": {"type": "json_object"},
            "messages": [{"role": "system", "content": sys_prompt},
                         {"role": "user", "content": user}]}
    req = urllib.request.Request(
        f"{JUDGE_URL}/chat/completions", data=json.dumps(body).encode(),
        headers={"content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        out = json.loads(r.read())["choices"][0]["message"]["content"]
    m = re.search(r"\{.*\}", out, re.S)
    v = json.loads(m.group(0)) if m else {}
    return {"correct": bool(v.get("correct", False)),
            "score": float(v.get("score", 0)), "reason": v.get("reason", ""),
            "rubric": rubric}


if __name__ == "__main__":
    import sys
    print(judge(sys.argv[1], sys.argv[2], sys.argv[3],
                context=sys.argv[4] if len(sys.argv) > 4 else None))
