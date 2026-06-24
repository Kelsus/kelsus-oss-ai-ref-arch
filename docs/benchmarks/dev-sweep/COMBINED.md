# Dev-tier model sweep — both axes together

Same instance (g6e.xlarge / 1× L40S), same workloads, 2026-06.
Fixed retrieval (identical embeddings + reranker); only the generation model varies.

| model | extraction F1 | RAG cov / ground | peak tok/s | TTFT p99 @64 | $/M out tok |
|---|---:|---:|---:|---:|---:|
| **Qwen2.5-7B-Instruct** | **99.0%** | 100% / 100% | 2,320 | 144 ms | $0.22 |
| **Phi-3.5-mini** (3.8B) | 92.7% | 100% / 100% | **3,494** | 118 ms | **$0.15** |
| **Qwen2.5-VL-7B** | 87.5% | 100% / 100% | 2,389 | 153 ms | $0.22 |

## Findings

1. **No single winner — it's workload-dependent.** Exactly why we publish per-workload, not a composite score.
2. **Best text quality: Qwen2.5-7B (99% extraction F1)** — at the *same* cost and speed as the VL model. If you don't need vision, the text-specialized 7B is the pick.
3. **Phi-3.5-mini is the cost-optimized choice** — fastest (3,494 tok/s) and cheapest ($0.15/M), and its quality holds up (92.7% F1). "Cheaper" did **not** mean "much worse" here — a genuinely viable option when budget dominates.
4. **Vision carries a text-quality cost.** Qwen2.5-VL can read scanned/image documents (the others can't), but it is the lowest on pure-text extraction F1 (87.5%). Pay for vision only when the inputs actually require it.

## Honest caveat
The RAG proxy (fact coverage + grounding) **saturated at 100%** for all three — the questions weren't hard enough to separate models, and keyword coverage is a coarse signal. Real RAG-quality differentiation needs the LLM-as-judge eval (Benchmark Index scope), with harder, adversarial questions. Extraction F1 (clean Synthea gold labels) is the trustworthy signal in this sweep.

> Caveat on scale: these are ~7B models that fit one L40S. The strategy's real
> candidates (DeepSeek V4, Qwen 3.5 235B, GLM-5, Kimi K2.6, Llama 4, Mistral) are
> large MoE models requiring the scale tier (g6e.12xlarge). This dev sweep proves
> the *method*; the production default is decided on that tier.
