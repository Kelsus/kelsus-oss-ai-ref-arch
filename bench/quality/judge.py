#!/usr/bin/env python3
"""LLM-as-judge for RAG answer quality — replaces the saturated keyword proxy.

Given (question, reference answer, candidate answer), an independent judge model
scores correctness + faithfulness. Use a STRONGER/independent model as judge
where possible (methodology wants a panel; dev may reuse the served model with a
documented caveat). Judge endpoint is separate via env so it can point elsewhere.

  JUDGE_URL  (default = VLLM_URL or http://127.0.0.1:8000/v1)
  JUDGE_MODEL (default 'local')
"""
import json
import os
import re
import urllib.request

JUDGE_URL = os.environ.get("JUDGE_URL", os.environ.get("VLLM_URL", "http://127.0.0.1:8000/v1"))
JUDGE_MODEL = os.environ.get("JUDGE_MODEL", "local")

_SYS = ("You are a strict grader for a financial-regulation QA system. Compare the "
        "CANDIDATE answer to the REFERENCE answer for the QUESTION. Return JSON "
        "{\"correct\": true|false, \"score\": 0-100, \"reason\": \"...\"}. "
        "correct=true only if the candidate is factually consistent with the "
        "reference and does not add unsupported claims. Brevity is fine.")


def judge(question, reference, candidate, timeout=60):
    user = (f"QUESTION: {question}\n\nREFERENCE: {reference}\n\n"
            f"CANDIDATE: {candidate}\n\nGrade:")
    body = {"model": JUDGE_MODEL, "temperature": 0, "max_tokens": 200,
            "response_format": {"type": "json_object"},
            "messages": [{"role": "system", "content": _SYS},
                         {"role": "user", "content": user}]}
    req = urllib.request.Request(
        f"{JUDGE_URL}/chat/completions", data=json.dumps(body).encode(),
        headers={"content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        out = json.loads(r.read())["choices"][0]["message"]["content"]
    m = re.search(r"\{.*\}", out, re.S)
    v = json.loads(m.group(0)) if m else {}
    return {"correct": bool(v.get("correct", False)),
            "score": float(v.get("score", 0)), "reason": v.get("reason", "")}


if __name__ == "__main__":
    import sys
    print(judge(sys.argv[1], sys.argv[2], sys.argv[3]))
