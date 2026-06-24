"""Kelsus Sovereign AI Gateway — the in-VPC entrypoint for both apps.

Runs inside the cluster and talks to vLLM, embeddings (TEI), and pgvector over
internal service DNS, so applications never need laptop port-forwards. Owns the
cross-cutting guards: PII redaction (defense in depth) and answer grounding.

Endpoints:
  GET  /health
  POST /rag/query   {q, k?}            -> grounded answer + citations (App 2)
  POST /extract     multipart pdf file -> structured fields (App 1)
"""
import base64
import contextlib
import io
import json
import os
import re
import time
import urllib.request

import psycopg2
from fastapi import FastAPI, File, Form, UploadFile
from pydantic import BaseModel
from pypdf import PdfReader

VLLM_URL = os.environ.get("VLLM_URL", "http://vllm:8000/v1")
EMBED_URL = os.environ.get("EMBED_URL", "http://embeddings:80")
# No password in the DSN (SOC2 CC6: no creds in source). libpq/psycopg2 reads it
# from PGPASSWORD, injected from the `rag-db` k8s secret in the deployment.
PG_DSN = os.environ.get("PG_DSN", "postgresql://rag@pgvector:5432/rag")
RERANK_URL = os.environ.get("RERANK_URL", "http://reranker:80")
MODEL = os.environ.get("MODEL", "local")
TOP_K = int(os.environ.get("TOP_K", "5"))
FETCH_N = int(os.environ.get("FETCH_N", "20"))   # vector candidates before rerank

# Generation provider. "local" = the in-cluster vLLM (default, unchanged). "bedrock"
# and "anthropic" route the SAME prompts to managed APIs so the benchmark can compare
# the same workload across substrates — only the generation model swaps; retrieval,
# prompts, vision routing, scoring, and the judge stay identical.
PROVIDER = os.environ.get("PROVIDER", "local").lower()
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
BEDROCK_MODEL_ID = os.environ.get("BEDROCK_MODEL_ID", "")      # e.g. us.anthropic.claude-opus-4-8
ANTHROPIC_MODEL_ID = os.environ.get("ANTHROPIC_MODEL_ID", "")  # e.g. claude-opus-4-8
ANTHROPIC_API_KEY = os.environ.get("ANTHROPIC_API_KEY", "")    # from k8s secret; never hardcoded
ANTHROPIC_VERSION = os.environ.get("ANTHROPIC_VERSION", "2023-06-01")

app = FastAPI(title="Kelsus Sovereign AI Gateway")

# --- PII redaction (data here is synthetic; this is defense in depth) --------
_PII = [
    (re.compile(r"\b\d{3}-\d{2}-\d{4}\b"), "[SSN]"),
    (re.compile(r"\b[\w.+-]+@[\w-]+\.[\w.-]+\b"), "[EMAIL]"),
    (re.compile(r"\b\d{3}[.-]\d{3}[.-]\d{4}\b"), "[PHONE]"),
]


def redact(t: str) -> str:
    for rx, repl in _PII:
        t = rx.sub(repl, t)
    return t


def _post(url, payload, timeout=int(os.environ.get("LLM_TIMEOUT", "600"))):  # ceiling, not a slowdown; reasoning models (DeepSeek) need >180s
    req = urllib.request.Request(
        url, data=json.dumps(payload).encode(),
        headers={"content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def embed(texts):
    return _post(f"{EMBED_URL}/embed", {"inputs": texts})


def rerank(query, texts):
    # TEI /rerank -> [{"index": i, "score": s}, ...] sorted by score desc
    return _post(f"{RERANK_URL}/rerank", {"query": query, "texts": texts}, timeout=60)


def vlit(v):
    return "[" + ",".join(f"{x:.6f}" for x in v) + "]"


# Reasoning models (DeepSeek-V3.1 etc.) emit <think>...</think> before the
# answer; max_tokens must leave room for it, and the reasoning must be stripped
# before JSON/answer parsing. LLM_MAX_TOKENS is a ceiling — it doesn't change
# what non-reasoning models emit.
LLM_MAX_TOKENS = int(os.environ.get("LLM_MAX_TOKENS", "400"))
_THINK = re.compile(r"<think>.*?</think>", re.S)


def _strip_reasoning(s):
    if not s:                             # reasoning models can return null/empty content
        return ""                         # (answer in reasoning_content, or budget spent on reasoning)
    s = _THINK.sub("", s)                 # closed reasoning blocks
    if "</think>" in s:                   # dangling open (truncated reasoning)
        s = s.split("</think>", 1)[1]
    return s.strip()


# --- generation: one interface, three providers ----------------------------
# user_parts is a list of {"text": str} and/or {"image": (bytes, mime)}; each
# provider helper returns (text, in_tokens, out_tokens).

def _img_fmt(mime):
    f = (mime or "").split("/")[-1].lower()
    return "jpeg" if f in ("jpg", "jpeg") else (f if f in ("png", "gif", "webp") else "png")


_bedrock_client = None


def _bedrock():
    global _bedrock_client
    if _bedrock_client is None:
        import boto3  # lazy: only the bedrock path needs it
        _bedrock_client = boto3.client("bedrock-runtime", region_name=AWS_REGION)
    return _bedrock_client


def _gen_local(system_text, user_parts, json_mode, max_tokens):
    if all("text" in p for p in user_parts):                 # text-only: plain string (unchanged path)
        user_content = "\n".join(p["text"] for p in user_parts)
    else:                                                    # vision: OpenAI content parts
        user_content = []
        for p in user_parts:
            if "text" in p:
                user_content.append({"type": "text", "text": p["text"]})
            else:
                b, mime = p["image"]
                user_content.append({"type": "image_url", "image_url":
                                     {"url": f"data:{mime};base64,{base64.b64encode(b).decode()}"}})
    messages = ([{"role": "system", "content": system_text}] if system_text else []) + \
               [{"role": "user", "content": user_content}]
    body = {"model": MODEL, "messages": messages, "temperature": 0,
            "max_tokens": max_tokens or LLM_MAX_TOKENS}
    if json_mode:
        body["response_format"] = {"type": "json_object"}
    resp = _post(f"{VLLM_URL}/chat/completions", body)
    u = resp.get("usage") or {}
    msg = resp["choices"][0]["message"]
    # Reasoning models (GLM-4.7, DeepSeek) served with a vLLM --reasoning-parser put
    # the answer in "content" and reasoning in "reasoning_content" — but "content" is
    # null when the answer didn't materialize (reasoning ate the token budget). Coalesce
    # so the gateway never feeds None downstream (the SE that 500'd the GLM-4.7 run).
    text = msg.get("content") or msg.get("reasoning_content") or ""
    return text, u.get("prompt_tokens"), u.get("completion_tokens")


def _gen_bedrock(system_text, user_parts, json_mode, max_tokens):
    content = []
    for p in user_parts:
        if "text" in p:
            content.append({"text": p["text"]})
        else:
            b, mime = p["image"]
            content.append({"image": {"format": _img_fmt(mime), "source": {"bytes": b}}})
    messages = [{"role": "user", "content": content}]
    # No assistant prefill: Opus 4.8 rejects it on Converse ("conversation must end
    # with a user message"). JSON is enforced by the prompt + the caller's {...}
    # regex extraction — the same path every model's output goes through.
    kwargs = {"modelId": BEDROCK_MODEL_ID, "messages": messages,
              "inferenceConfig": {"maxTokens": max_tokens or LLM_MAX_TOKENS}}  # no temperature: Opus 4.8 rejects it
    if system_text:
        kwargs["system"] = [{"text": system_text}]
    resp = _bedrock().converse(**kwargs)
    text = "".join(b.get("text", "") for b in resp["output"]["message"]["content"])  # skip reasoningContent
    u = resp.get("usage") or {}
    return text, u.get("inputTokens"), u.get("outputTokens")


def _gen_anthropic(system_text, user_parts, json_mode, max_tokens):
    content = []
    for p in user_parts:
        if "text" in p:
            content.append({"type": "text", "text": p["text"]})
        else:
            b, mime = p["image"]
            content.append({"type": "image", "source": {"type": "base64",
                            "media_type": mime, "data": base64.b64encode(b).decode()}})
    messages = [{"role": "user", "content": content}]
    # No assistant prefill (Opus 4.8 rejects it); JSON via the prompt + {...} regex extraction.
    body = {"model": ANTHROPIC_MODEL_ID, "max_tokens": max_tokens or LLM_MAX_TOKENS,
            "messages": messages}
    if system_text:
        body["system"] = system_text
    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages", data=json.dumps(body).encode(),
        headers={"content-type": "application/json", "x-api-key": ANTHROPIC_API_KEY,
                 "anthropic-version": ANTHROPIC_VERSION})
    with urllib.request.urlopen(req, timeout=int(os.environ.get("LLM_TIMEOUT", "600"))) as r:
        resp = json.loads(r.read())
    text = "".join(b.get("text", "") for b in resp.get("content", []) if b.get("type") == "text")
    u = resp.get("usage") or {}
    return text, u.get("input_tokens"), u.get("output_tokens")


def _generate(system_text, user_parts, json_mode=False, max_tokens=None):
    """Dispatch to the configured provider; return (text, meta). meta carries the
    token usage + latency the benchmark aggregates into managed_perf."""
    t0 = time.monotonic()
    if PROVIDER == "bedrock":
        text, ti, to = _gen_bedrock(system_text, user_parts, json_mode, max_tokens)
        model = BEDROCK_MODEL_ID
    elif PROVIDER == "anthropic":
        text, ti, to = _gen_anthropic(system_text, user_parts, json_mode, max_tokens)
        model = ANTHROPIC_MODEL_ID
    else:
        text, ti, to = _gen_local(system_text, user_parts, json_mode, max_tokens)
        model = MODEL
    meta = {"provider": PROVIDER, "model": model, "in_tokens": ti, "out_tokens": to,
            "latency_ms": round((time.monotonic() - t0) * 1000, 1)}
    return _strip_reasoning(text), meta


def llm(messages, json_mode=False, max_tokens=None):
    """[{role:system,...},{role:user,...}] -> (text, meta)."""
    system_text = next((m["content"] for m in messages if m["role"] == "system"), "")
    user_text = "\n".join(m["content"] for m in messages if m["role"] == "user")
    return _generate(system_text, [{"text": user_text}], json_mode, max_tokens)


def llm_vision(instruction, image_bytes, mime="image/png", max_tokens=None):
    """Image -> vision-language model (no separate OCR) -> (text, meta)."""
    return _generate("", [{"text": instruction}, {"image": (image_bytes, mime)}],
                     json_mode=True, max_tokens=max_tokens)


def render_pdf_page(pdf_bytes, page=0, zoom=2.0):
    """Rasterize a (scanned) PDF page to PNG bytes for the vision model."""
    import fitz  # PyMuPDF
    doc = fitz.open(stream=pdf_bytes, filetype="pdf")
    pix = doc[page].get_pixmap(matrix=fitz.Matrix(zoom, zoom))
    return pix.tobytes("png")


@app.get("/health")
def health():
    return {"status": "ok"}


class Query(BaseModel):
    q: str
    k: int | None = None


@app.post("/rag/query")
def rag_query(req: Query):
    k = req.k or TOP_K
    qv = vlit(embed([req.q])[0])
    # contextlib.closing: psycopg2's `with conn` closes the TRANSACTION, not the
    # connection — under concurrency that leaks connections until Postgres
    # refuses new ones (RAG 500s; SE-15). closing() actually closes it each call.
    with contextlib.closing(psycopg2.connect(PG_DSN)) as c, c.cursor() as cur:
        cur.execute(
            "SELECT title,source,content,1-(embedding <=> %s::vector) "
            "FROM chunks ORDER BY embedding <=> %s::vector LIMIT %s",
            (qv, qv, FETCH_N))            # over-fetch, then rerank
        hits = cur.fetchall()
    if not hits:
        return {"answer": "No documents have been ingested yet.", "citations": []}
    reranked = False
    try:                                  # cross-encoder rerank; fall back to vector order
        order = rerank(req.q, [h[2] for h in hits])
        hits = [hits[o["index"]] for o in order][:k]
        reranked = True
    except Exception:                     # noqa: BLE001
        hits = hits[:k]
    context = "\n\n".join(f"[{i+1}] (source: {h[1]})\n{h[2]}"
                          for i, h in enumerate(hits))
    system = ("You answer strictly from the provided CONTEXT about financial "
              "regulation. Cite sources you use with bracketed numbers like [1]. "
              "If the answer is not in the context, say exactly: \"I don't know "
              "based on the provided documents.\"")
    ans, meta = llm([{"role": "system", "content": system},
                     {"role": "user",
                      "content": f"CONTEXT:\n{context}\n\nQUESTION: {req.q}\n\nAnswer with citations:"}])
    return {
        "answer": ans,
        "reranked": reranked,
        "citations": [{"n": i + 1, "title": h[0], "source": h[1],
                       "score": round(h[3], 3)} for i, h in enumerate(hits)],
        "_meta": meta,
    }


_EXTRACT_SYS = (
    "You extract structured data from a medical claim/invoice. Return ONLY a "
    "JSON object with exactly these keys: patient_name, payer_name, "
    "provider_name, provider_npi, service_date (YYYY-MM-DD), total_billed "
    "(number), balance_due (number), num_line_items (integer). Use null for "
    "any field not present.")

_EXTRACT_COMMERCIAL_SYS = (
    "You extract structured data from a commercial invoice. Return ONLY a JSON "
    "object with exactly these keys: invoice_number, invoice_date (as printed), "
    "due_date (as printed), total (number), seller, buyer_name. Use null for any "
    "field not present.")

_SCHEMAS = {"medical": _EXTRACT_SYS, "commercial": _EXTRACT_COMMERCIAL_SYS}


@app.post("/extract")
async def extract(file: UploadFile = File(...), domain: str = Form("medical")):
    """Image -> vision model. Digital PDF -> text. Scanned PDF -> rasterize -> vision.
    domain selects the field schema (medical | commercial)."""
    data = await file.read()
    name = (file.filename or "").lower()
    ctype = file.content_type or ""
    sys = _SCHEMAS.get(domain, _EXTRACT_SYS)

    if name.endswith((".png", ".jpg", ".jpeg", ".webp")) or ctype.startswith("image/"):
        out, meta = llm_vision(sys, data, mime=ctype or "image/png")
        mode = "vision"
    else:
        text = "\n".join((p.extract_text() or "")
                         for p in PdfReader(io.BytesIO(data)).pages)
        if len(text.strip()) >= 40:                     # has a usable text layer
            out, meta = llm([{"role": "system", "content": sys},
                             {"role": "user", "content": "INVOICE:\n" + redact(text)}],
                            json_mode=True)
            mode = "text"
        else:                                           # scanned/image-only PDF
            out, meta = llm_vision(sys, render_pdf_page(data), mime="image/png")
            mode = "vision"

    m = re.search(r"\{.*\}", out, re.S)
    return {"mode": mode, "domain": domain, "fields": json.loads(m.group(0)) if m else {}, "_meta": meta}
