# Scale-tier benchmark — raw results (official archive)

Version-controlled copies of the canonical scale-tier (8-GPU) benchmark outputs,
pulled from `s3://kelsus-refarch-models-scale-<acct>/results/`. Committed so the
raw, reproducible data lives with the code, not just in a dev S3 bucket.

Synthetic data only (ADR-0004); the `*.json` carry each model's 250 collected
RAG answers (model outputs over the synthetic regulated-finance QA) — no PII.

## Files
| File | Model | Config | Notes |
|---|---|---|---|
| `glm-4.5-air__*.json` | GLM-4.5-Air (110B MoE, MIT) | TP=8, BF16 | clean-digital extraction + RAG answers |
| `qwen3-235b-a22b-fp8__*.json` | Qwen3-235B-A22B (Apache) | TP=8, FP8, expert-parallel | extraction + RAG answers |
| `llama4-scout__*.json` | Llama-4-Scout (109B MoE) | TP=8, BF16 | full tiers + commercial + RAG |
| `qwen2.5-vl-72b__*.json` | Qwen2.5-VL-72B | TP=8 | extraction + RAG answers |
| `deepseek-v3.1-awq__*.json` | DeepSeek-V3.1-AWQ (671B) | vLLM 0.9.2 recipe, TP=8, no-EP (SE-19) | extraction 96.3% + RAG answers |
| `kimi-k2-instruct__*.json` | Kimi-K2-Instruct (1T MoE, RedHat w4a16) | 8×H200, vLLM 0.10.0, blobfile dep (SE-21) | extraction 94.8% (n=122) + RAG answers; tops RAG @ 43.2% |
| `<model>.judged.json` | — | — | per-model fixed-judge RAG verdict (`Qwen2.5-VL-72B-Instruct` judge, vLLM **v0.23.0 pinned** — SE-22) |
| `rag-fixed-judge.txt` | — | — | the comparable RAG table (**all 6 models, one judge — 2026-06-17 baseline**) |

Headline numbers and honest caveats: [`../rag-fixed-judge.md`](../rag-fixed-judge.md),
[`../scale-validation-72b.md`](../scale-validation-72b.md). Filenames keep the
UTC run timestamp for provenance.
