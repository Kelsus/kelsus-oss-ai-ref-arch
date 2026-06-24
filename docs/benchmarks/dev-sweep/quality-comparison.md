# Model sweep — quality (App 1 extraction + App 2 RAG)

Fixed retrieval (same embeddings + reranker); only the generation model varies.

| model | extraction F1 | RAG fact coverage | RAG grounding |
|---|---:|---:|---:|
| Qwen/Qwen2.5-7B-Instruct | 99.0% | 100.0% | 100.0% |
| microsoft/Phi-3.5-mini-instruct | 92.7% | 100.0% | 100.0% |
| Qwen/Qwen2.5-VL-7B-Instruct | 87.5% | 100.0% | 100.0% |

_Pair with the cost/latency sweep for the full picture — cheapest/fastest ≠ best when quality on the target workload matters. RAG metrics here are a directional proxy; full LLM-judge eval is Index scope._
