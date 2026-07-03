# Applications

Two apps exercise the stack end-to-end and emit the benchmark numbers. Both talk
only to the gateway's OpenAI-compatible endpoint, so the underlying model is a
config swap ([ADR-0002](../docs/decisions/0002-eks-vllm-serving-substrate.md)).

## gateway/  (Sprint 2)
FastAPI in front of vLLM + retrieval. Owns the cross-cutting concerns:
- **Substrate comparability** — identical prompts, temperature 0, and JSON handling
  across local vLLM / Bedrock / Anthropic, so benchmark columns differ only in the model.
- **Grounding by prompt** (answers must cite the retrieved context; the fixed judge scores it).
- A PII `redact()` utility exists but is NOT applied on the benchmark path (synthetic
  data; v1 applied it asymmetrically to only the digital-text path, which confounded
  the vision-vs-text comparison).
- Token/latency provenance per request in `_meta` (usage, `finish_reason`, effective temperature).

## claims-intake/  (App 1 — Document Workflow Pilot proof; the Varent rebuild)
Pipeline: **ingest → extract → classify → route → reconcile → chase** over synthetic
medical claims/invoices ([`data/synthea`](../data/synthea), [`data/desynpuf`](../data/desynpuf), [`data/fatura`](../data/fatura)).
Emits: field-level **extraction F1** (vs gold), classification accuracy, agentic
end-to-end completion rate, throughput, $/M-token.

## sovereign-rag/  (App 2 — Sovereign RAG Platform proof)
Pipeline: **retrieve + rerank → answer with citations → grounding guard** over the
public regulated-finance corpus ([`data/corpus`](../data/corpus)).
Emits: RAG answer quality (LLM-judge + grounding F1), citation correctness,
long-context behavior, TTFT/p95.

Each app is both an SKU proof and a benchmark driver; results land in [`bench/`](../bench).
