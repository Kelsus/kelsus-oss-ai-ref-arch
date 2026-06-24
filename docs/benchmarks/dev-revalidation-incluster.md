# Dev-tier re-validation — realistic eval, run fully in-cluster

First complete run of the **representative** eval (multi-template medical ×
degradation tiers + FATURA commercial × degradation tiers + judge-scored RAG),
executed as an **in-cluster Job** (no laptop, tunnel, or SSO in the loop; data
in from S3 via Pod Identity, results out to `s3://…/results/quality/`).
Model: Qwen2.5-VL-7B-Instruct on 1× L40S. 2026-06-10.

## Results (Wilson 95% CIs)

| Workload | Tier | F1 / accuracy | CI | n |
|---|---|---:|---|---:|
| Medical extraction | clean-digital | 96.4% | [94.8, 97.5] | 100 |
| Medical extraction | scanned-clean | 97.7% | [96.4, 98.5] | 97 |
| **Medical extraction** | **scanned-degraded (headline)** | **93.7%** | [91.7, 95.2] | 95 |
| Commercial (FATURA) | scanned-clean | 90.2% | [85.9, 93.3] | 51 |
| **Commercial (FATURA)** | **scanned-degraded (headline)** | **70.6%** | [64.7, 75.8] | 51 |
| **RAG (LLM-judge)** | 2,943-chunk corpus | **38.8%** | [32.9, 45.1] | 242 |

## Reproducibility check
An earlier laptop-driven run of the same eval produced 94.6 / 70.7 (degraded
headlines) and RAG 41.2 — all within each other's CIs. Two independent runs,
two execution paths, consistent results.

## What the per-field detail says (where a 7B breaks)
- **Degraded medical:** `provider_npi` collapses to **67.4%** (long UUIDs off a
  noisy scan) and `num_line_items` 91.6% (counting); everything else ≥96%.
- **Degraded commercial:** `invoice_number` **41.2%**, `buyer_name` **45.1%** —
  varied real layouts + scan wear is where the small model genuinely fails.
  `total` stays 96.1% (big bold numbers survive degradation).
- These are exactly the fields where the scale-tier candidates (Mistral Large,
  Qwen 235B, DeepSeek V4, Kimi K2) should differentiate.
- RAG note: n=242/250 — 8 questions failed on a transient gateway connection
  error during the run (logged); limiter remains retrieval recall + same-model
  judging (independent judge planned for the Index).

## Operational note
Mid-run, the nightly GPU dead-man's switch (06:00 UTC) terminated the static
GPU node — and **Karpenter automatically provisioned a replacement** for the
Pending vLLM pod; the model reloaded and the Job completed on the new node.
Unplanned, unattended live test of the self-healing path: passed.
