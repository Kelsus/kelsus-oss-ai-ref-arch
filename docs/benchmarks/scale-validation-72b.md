# Scale-tier validation — Qwen2.5-VL-72B (TP=8, 8× A100 spot)

Task #4 closeout. Purpose: validate multi-GPU tensor-parallel serving and the
full eval pipeline at scale, and answer the question the dev results posed —
*does scale fix what the 7B got wrong?* 2026-06-11, us-west-2.

**Hardware:** `p4d.24xlarge` (8× A100 40GB), **spot** (~$9/hr), Karpenter-provisioned.
Planned H100 (p5) was capacity-unavailable on spot at run time; A100 substituted
by decision (Jon) — quality results are model-dependent, not silicon-dependent.
H100s remain required + planned for the frontier-MoE sweep (task #5), which
cannot run on A100-40.

## Quality: 7B vs 72B, identical eval (same data, same gateway, same scorer)

| Workload | Qwen2.5-VL-**7B** | Qwen2.5-VL-**72B** | Δ |
|---|---:|---:|---|
| Medical, clean-digital | 96.4% [94.8,97.5] | 96.8% [95.3,97.8] | ≈ |
| Medical, scanned-clean | 97.7% [96.4,98.5] | 98.1% [96.8,98.9] | ≈ |
| **Medical, scanned-degraded** | 93.7% [91.7,95.2] | **96.5%** [94.9,97.6] | **+2.8** |
| Commercial (FATURA), scanned-clean | 90.2% [85.9,93.3] | 91.0% [86.3,94.1] | ≈ |
| **Commercial (FATURA), scanned-degraded** | 70.6% [64.7,75.8] | **74.5%** [68.0,80.0] | **+3.9** |

Hard-field detail (degraded tiers): provider NPI/UUID 67%→**76%**; commercial
invoice_number 41%→**50%**; buyer_name ≈45% (both); totals/dates ≥90% (both).

### Findings
1. **Scale pays only where vision is hard.** Clean documents: statistical tie —
   do not pay 10× for clean digital intake. Degraded scans: consistent gains,
   concentrated in exactly the fields the 7B failed (IDs, long alphanumerics).
2. **Degraded real-world layouts stay hard even at 72B** (74.5% on FATURA
   degraded). Scale is a lever, not a cure; pipeline design (de-skew/upscale
   preprocessing, field-targeted prompting) is the other lever.

## RAG: the judge confound, demonstrated
7B run: 38.8% [32.9,45.1] (7B judged by 7B). 72B run: **30.0%** [24.7,35.9]
(72B judged by 72B). These are **not comparable** — the judge changed with the
model, and stronger judges grade harder. This empirically confirms the Index
methodology's rule: cross-model RAG comparison requires a **fixed, independent
judge**. No RAG ranking is published until that is in place.

## Run integrity notes (honest accounting)
- A transient gateway outage dropped ~156 eval items (medical n=282/400,
  commercial n=82/120, RAG n=250/250 second run). CIs reflect the reduced n.
- Cost/latency numbers measured separately on the same box — see
  [`dev-sweep/`](dev-sweep/) + raw runs in `bench/reports/runs/` and the
  summary appended to this file by the perf harvest.
- The run validated: Karpenter spot provisioning (after the SLR fix), TP=8
  serving, in-cluster eval with S3 results, multi-region reproduce-from-code.

## Performance: 72B on 8× A100 (TP=8), measured

| Concurrency | TTFT p50/p95 (ms) | total p95 (ms) | aggregate tok/s |
|---:|---|---:|---:|
| 1 | 48 / 48 | 5,068 | 47 |
| 8 | 56 / 57 | 5,179 | 343 |
| 32 | 83 / 274 | 6,580 | 1,190 |
| 64 | 132 / 187 | 6,611 | **2,283** |

Zero errors at every level. **$/M output tokens at the actual spot price paid
($11.99/hr, us-west-2b):** peak **$1.46** · 90% util $1.62 · 60% $2.43 · 30% $4.86.

Context: the 7B on one L40S peaked at 2,375 tok/s for ~$0.22/M — the 72B costs
~6–7× more per token for its quality gains on hard documents. That trade, per
tier, is the decision this benchmark exists to inform. Raw data:
`bench/reports/runs/20260611T071351/`.
