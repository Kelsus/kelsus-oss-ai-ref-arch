# RAG quality — single fixed-judge pass (comparable across models)

Every model's RAG answers were **collected** during its own run, then graded in
one pass by a **single fixed judge** (`Qwen2.5-VL-72B-Instruct`, served as `local`
on vLLM **v0.23.0, pinned**), so the numbers are directly comparable. This is the
methodologically-correct replacement for the earlier per-model self-judging (the
confound demonstrated in the 72B validation). Same retrieval+rerank pipeline and
same 250 grounded regulated-finance QA pairs for all; only the generating model
differs.

**Baseline: 2026-06-17, 6 models, one judge pass.**

| Model | RAG accuracy | 95% CI | n |
|---|---:|---|---:|
| **Kimi-K2-Instruct** (w4a16) | **43.2%** | [37.2, 49.4] | 250 |
| GLM-4.5-Air | 36.4% | [30.7, 42.5] | 250 |
| DeepSeek-V3.1-AWQ | 36.4% | [30.7, 42.5] | 250 |
| Qwen2.5-VL-72B | 28.0% | [22.8, 33.9] | 250 |
| Llama-4-Scout | 25.2% | [20.2, 30.9] | 250 |
| Qwen3-235B-A22B-FP8 | 23.6% | [18.8, 29.2] | 250 |

## Reading this honestly
- **Kimi-K2-Instruct leads — directionally, not decisively.** It is the single
  best RAG performer (~7 pts above the GLM/DeepSeek tier), which is a real signal.
  But its CI [37.2, 49.4] overlaps GLM/DeepSeek's [30.7, 42.5]; at n=250 (±~6 pts)
  this is a soft #1, not a statistically clean win.
- **RAG accuracy is low across the whole board (23–43%).** That is a stack-level
  ceiling — retrieval quality, prompt, and judge strictness against the gold
  answers — not primarily a model-choice problem. Swapping in a stronger generator
  buys a few points; it does not get you to "good." The lever for better RAG is the
  retrieval/prompt/judge-rubric, not the generation model.
- **Absolute numbers are low by design** — a strict judge over hard, grounded
  regulated-finance QA. The value is the *relative, same-judge* comparison.
- **Judge-family caveat:** the judge (`Qwen2.5-VL-72B-Instruct`) shares a family
  with two candidates (Qwen3-235B, Qwen2.5-VL-72B); they did not score highest, so
  no obvious self-favoritism, but a fully independent judge is a future refinement.
- **Not in this pass:** Qwen2.5-VL-7B (dev) was inline-judged with no collected
  answers; add via a cheap dev re-collect to complete the set.

## Why this run supersedes the earlier table (SE-22)
An earlier 5-model fixed-judge table reported higher numbers (GLM 45.6%, DeepSeek
43.2%, …). It is **not comparable to this one and has been retired.** The judge's
manifest pinned `vllm/vllm-openai:latest`, which had silently rolled forward to a
newer vLLM; re-judging the identical collected answers on it shifted *every* model
down 6–12 pts (a uniformly stricter scoring regime — same judge weights, different
serving stack). A fixed judge is only fixed if its image is **version-locked**, so
`vllm-scale.yaml` is now pinned to `v0.23.0`. This 6-model pass — one judge, one
version, one run — is the authoritative comparable baseline; do **not** mix its
numbers with the retired table.

Raw: `s3://kelsus-refarch-models-scale-<acct>/results/quality/*.json` (each carries
its 250 collected answers) and the per-model `*.judged.json` beside `judge_pass.py`.
