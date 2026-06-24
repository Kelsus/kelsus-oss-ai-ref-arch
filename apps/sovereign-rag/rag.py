#!/usr/bin/env python3
"""Sovereign RAG (App 2) — retrieval-augmented Q&A with grounded citations.

Pipeline, all inside the VPC:
  ingest:  docs -> chunk -> embed (TEI/BGE) -> store (Postgres+pgvector)
  ask:     question -> embed -> vector search -> prompt vLLM -> cited answer

Endpoints are read from env (defaults assume `run-local.sh` port-forwards):
  VLLM_URL   OpenAI-compatible LLM         (default http://127.0.0.1:8000/v1)
  EMBED_URL  TEI embeddings                (default http://127.0.0.1:8081)
  PG_DSN     Postgres+pgvector             (default postgresql://rag@127.0.0.1:55432/rag; PGPASSWORD supplies the password)

Usage:
  python3 rag.py init
  python3 rag.py ingest data/corpus/seed
  python3 rag.py ask "What has the CFPB proposed about overdraft fees?"
"""
import json
import os
import sys
import urllib.request

import psycopg2

VLLM_URL = os.environ.get("VLLM_URL", "http://127.0.0.1:8000/v1")
EMBED_URL = os.environ.get("EMBED_URL", "http://127.0.0.1:8081")
PG_DSN = os.environ.get("PG_DSN", "postgresql://rag@127.0.0.1:55432/rag")  # password via PGPASSWORD env
MODEL = os.environ.get("MODEL", "local")
EMBED_DIM = 768
TOP_K = int(os.environ.get("TOP_K", "5"))


def _post(url, payload, timeout=180):
    req = urllib.request.Request(
        url, data=json.dumps(payload).encode(),
        headers={"content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def embed(texts):
    """TEI /embed: {'inputs': [...]} -> [[...768...], ...]"""
    return _post(f"{EMBED_URL}/embed", {"inputs": texts})


def vlit(v):
    return "[" + ",".join(f"{x:.6f}" for x in v) + "]"


def init_db():
    with psycopg2.connect(PG_DSN) as c, c.cursor() as cur:
        cur.execute("CREATE EXTENSION IF NOT EXISTS vector;")
        cur.execute(f"""
            CREATE TABLE IF NOT EXISTS chunks (
              id serial PRIMARY KEY,
              title text, source text, chunk_idx int,
              content text, embedding vector({EMBED_DIM})
            );""")
        c.commit()
    print("db initialized (extension vector + table chunks)")


def chunk_text(t, size=1400, overlap=200):
    t = " ".join(t.split())
    out, i = [], 0
    while i < len(t):
        out.append(t[i:i + size])
        i += size - overlap
    return out


def load_docs(path):
    files = ([os.path.join(path, f) for f in os.listdir(path) if f.endswith(".jsonl")]
             if os.path.isdir(path) else [path])
    docs = []
    for f in files:
        with open(f) as fh:
            docs += [json.loads(ln) for ln in fh if ln.strip()]
    return docs


def ingest(path):
    docs = load_docs(path)
    rows = [(d.get("title", ""), d.get("source", ""), idx, ch)
            for d in docs for idx, ch in enumerate(chunk_text(d.get("text", "")))]
    if not rows:
        print(f"no chunks found under {path}"); return
    with psycopg2.connect(PG_DSN) as c, c.cursor() as cur:
        cur.execute("TRUNCATE chunks RESTART IDENTITY;")
        B = 32
        for i in range(0, len(rows), B):
            batch = rows[i:i + B]
            vecs = embed([r[3] for r in batch])
            for (title, source, idx, content), v in zip(batch, vecs):
                cur.execute(
                    "INSERT INTO chunks (title,source,chunk_idx,content,embedding) "
                    "VALUES (%s,%s,%s,%s,%s::vector)",
                    (title, source, idx, content, vlit(v)))
        c.commit()
    print(f"ingested {len(rows)} chunks from {len(docs)} docs")


def search(query, k=TOP_K):
    qv = vlit(embed([query])[0])
    with psycopg2.connect(PG_DSN) as c, c.cursor() as cur:
        cur.execute(
            "SELECT title, source, content, 1-(embedding <=> %s::vector) AS score "
            "FROM chunks ORDER BY embedding <=> %s::vector LIMIT %s",
            (qv, qv, k))
        return cur.fetchall()


def ask(query):
    hits = search(query)
    if not hits:
        print("No documents ingested. Run: rag.py ingest <path>"); return
    context = "\n\n".join(f"[{i+1}] (source: {h[1]})\n{h[2]}"
                          for i, h in enumerate(hits))
    system = ("You answer strictly from the provided CONTEXT about financial "
              "regulation. Cite the sources you use with bracketed numbers like "
              "[1]. If the answer is not in the context, say exactly: "
              "\"I don't know based on the provided documents.\"")
    user = f"CONTEXT:\n{context}\n\nQUESTION: {query}\n\nAnswer with citations:"
    resp = _post(f"{VLLM_URL}/chat/completions", {
        "model": MODEL,
        "messages": [{"role": "system", "content": system},
                     {"role": "user", "content": user}],
        "temperature": 0, "max_tokens": 400})
    ans = resp["choices"][0]["message"]["content"]
    print("\n=== QUESTION ===\n" + query)
    print("\n=== ANSWER (grounded) ===\n" + ans + "\n")
    print("=== RETRIEVED SOURCES ===")
    for i, h in enumerate(hits):
        print(f"[{i+1}] {h[0][:80]}  (cosine {h[3]:.3f})\n    {h[1]}")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "ask"
    if cmd == "init":
        init_db()
    elif cmd == "ingest":
        ingest(sys.argv[2] if len(sys.argv) > 2 else "data/corpus/seed")
    elif cmd == "ask":
        ask(" ".join(sys.argv[2:]) or "What recent federal rules concern consumer lending?")
    else:
        print(__doc__)
