# ADR-0003 — Best-on-benchmark model selection, not provenance optics

**Status:** Accepted · **Date:** 2026-06-05 (Jon)

## Context
The strongest open-weight models include both Western-origin (Llama 4, Mistral Large) and Chinese-origin (DeepSeek V4, Qwen 3.5, GLM-5, Kimi K2.6) families. A compliance-sensitive buyer raises a provenance question. We considered defaulting the reference build to a Western-provenance model purely for buyer optics.

## Decision
The reference deployment **defaults to whichever model wins the target workload on our published benchmark, regardless of origin.** We benchmark the full candidate set and let the measured winner be the default. Provenance is addressed honestly in the writeup as a separate axis from sovereignty:

- **Sovereignty** = where the model runs and who can see the data (we control this: it runs in the customer VPC, inspectable, air-gappable). This is what the architecture guarantees.
- **Provenance** = who trained the weights. We document each candidate's origin and license so the buyer can apply their own policy; we do not pre-decide it for them.

## Consequences
- Model selection is **evidence-led**, which protects the "we deploy what we benchmark" claim — we cannot be accused of crowning a model we didn't test.
- The writeup must carry a clear, non-defensive provenance-vs-sovereignty section.
- Candidate set for v1: DeepSeek V4, Qwen 3.5, GLM-5, Kimi K2.6, Llama 4, Mistral Large. License is evaluated at the benchmark cutoff date.
