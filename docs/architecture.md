# Sovereign LLM Inference on AWS — Reference Architecture

> This is the public writeup. Each measured claim is tagged with its evidence state:
> **`[MEASURED]`** — backed by raw data committed in this repo;
> **`[MEASURED · finalizing]`** — collected and in S3, being curated into `docs/benchmarks/` before release;
> **`[PENDING]`** — not yet captured.
> No marketing numbers: if it isn't measured, it isn't claimed. All data is **synthetic** (see §3, §7.1).

## 1. Executive summary
Frontier APIs win when raw capability and time-to-ship dominate. Sovereign deployment wins when data custody, regulation, or unit economics dominate. This document describes a purpose-built reference architecture for sovereign LLM inference and RAG on AWS, and the measured trade-offs at every layer: latency, cost per million tokens, scaling behavior, extraction quality, and operational footprint.

The headline finding from the benchmark: open-weight models on rentable-by-the-hour GPUs span a wide, *predictable* cost/quality range — from a 7-billion-parameter model on a single L40S at **$0.22 per million output tokens**, to a 235-billion-parameter mixture-of-experts and beyond on eight H100s at **~$1.00/M**, all inside the customer's VPC. Quality on real document work is tiered: clean digital documents are nearly solved even by small models; degraded scans are where larger models earn their cost, and where the work is genuinely hard. The architecture — Terraform, Helm, and the eval harness — is open in this repository.

## 2. Audience and scope
For platform-engineering leaders, ML-infrastructure engineers, and CIO/CISO advisory teams evaluating open-weight LLMs on infrastructure they control.
- **In scope:** single-region sovereign deployment; inference serving; RAG pipeline; VPC isolation; IAM; observability; autoscaling; latency/throughput/cost/quality benchmarks.
- **Out of scope (v1):** multi-region failover; on-prem/air-gapped; fine-tuning pipelines; agent orchestration above the inference layer.

## 3. Problem context
Document-intensive enterprise workloads — RAG over private corpora, structured extraction, classification, summarization — share three properties: large prompts, modest outputs, and a hard requirement that content never leaves the perimeter. That makes them the natural fit for sovereign open-weight deployment. The open question is no longer "is the model good enough" but "is the operational pattern repeatable, and what does it cost." This is our answer, measured on **fully synthetic** data so the whole benchmark is publishable and reproducible (§7.1).

## 4. Architecture at a glance
See [`README.md`](../README.md#architecture-at-a-glance) for the layer diagram ([`architecture-diagram.svg`](architecture-diagram.svg)). Six layers, all inside one VPC: platform (EKS + Karpenter), data & retrieval (S3, pgvector, in-VPC parsing), model serving (vLLM on GPU; embeddings and reranker on CPU), applications, guardrails & evaluation, and the interface — with security (IAM/IRSA, KMS CMK, private subnets) and observability spanning every layer. Weights are pulled once, at build time, into in-account S3; nothing on the serving path leaves the VPC.

## 5. Stack and rationale

### 5.1 Model selection — evidence-led `[MEASURED]` / `[MEASURED · finalizing]`
Per [ADR-0003](decisions/0003-best-on-benchmark-model-selection.md), the default model is chosen on benchmark performance for the workload, not on provenance optics, and provenance is documented honestly.

**Candidate set and what actually ran.** We set out to benchmark DeepSeek, Qwen, GLM, Kimi, Llama, and Mistral families. The models that ran:

| Model | Architecture | License | Role |
|---|---|---|---|
| Qwen2.5-VL-7B | 7B, vision-language | Apache-2.0 | dev baseline |
| Qwen2.5-VL-72B | 72B, vision-language | Apache-2.0 | scale reference |
| GLM-4.5-Air | 110B MoE (~12B active) | MIT | scale candidate |
| Qwen3-235B-A22B | 235B MoE, FP8 | Apache-2.0 | scale candidate |
| Llama-4-Scout | 109B MoE | Llama 4 Community (gated) | scale candidate |
| DeepSeek-V3.1 | 671B MoE, AWQ int4 | open-weight | frontier candidate |

**What we did *not* run, and why** (stated so the candidate list isn't mistaken for vaporware): **Mistral Large** — the tiered eval requires a vision path and Mistral Large is text-only and license-gated on Hugging Face; **Kimi K2** — no public INT4 quant exists and the native FP8 (~1 TB) exceeds a single 8-GPU box's 640 GB. Both are documented dead-ends, not omissions.

**The non-obvious findings** (dev two-axis sweep, [`docs/benchmarks/dev-sweep/COMBINED.md`](benchmarks/dev-sweep/COMBINED.md)):
- A **vision-language model is a worse pure-text extractor than its text-only sibling at equal cost** — Qwen2.5-VL-7B scored 87.5% F1 on clean digital invoices vs 99% for the text-only Qwen2.5-7B. Pay for vision only when the input needs it; route digital PDFs to the text path.
- "Cheaper" did not mean "much worse": Phi-3.5-mini (cheapest, fastest) held 92.7% on the same task.
- **Natively-multimodal ≠ document-vision-good.** Llama-4-Scout is the weakest vision extractor we tested — worse than the 7B Qwen-VL on degraded scans.

There is no single winner; the choice is per-workload and per-input-difficulty (§7.6).

### 5.2 Inference runtime — vLLM
vLLM ([ADR-0002](decisions/0002-eks-vllm-serving-substrate.md)): PagedAttention + continuous batching for throughput, tensor parallelism for the multi-GPU models (TP=4 on L40S, TP=8 on A100/H100), FP8/AWQ quantization, OpenAI-compatible API. Everything sits behind that API so the runtime is swappable. SGLang/TensorRT-LLM bake-off: `[PENDING]`.

### 5.3 Quantization
Served FP8 (Qwen3-235B) and AWQ int4 (DeepSeek-V3.1) for the models that need it to fit. Quality delta vs unquantized at equal model: `[PENDING]`. Practical note: FP8 block-quantized MoE needed `--enable-expert-parallel` to satisfy tensor-parallel divisibility (operational-learnings SE-11).

### 5.4 Compute
Karpenter provisions GPU on demand: `g6e.xlarge` (1× L40S) for dev; `g6e.12xlarge` (4× L40S, TP=4) for mid-size; `p4d`/`p5` (8× A100/H100, TP=8) for the 100B–671B models. Costs are actual spot prices paid, in §7 and §8.

### 5.5 Networking & VPC isolation
Internal ALB; egress allow-listed to VPC endpoints; the scale tier runs the full no-NAT posture ([ADR-0001](decisions/0001-sovereign-single-vpc-no-egress.md)).

### 5.6 Model artifact storage
S3 + KMS CMK; weights streamed to the GPU node on pod start. Cold weight-load ≈ 8–10 min for the small model; large-MoE load times: `[MEASURED · finalizing]`.

### 5.7 Observability
Prometheus (vLLM tokens/s, queue depth, GPU util, KV-cache), Grafana, CloudWatch.

### 5.8 Security posture
IRSA / EKS Pod Identity least-privilege; KMS for S3/EBS; TLS in transit; CloudTrail; namespace isolation. See §9.

## 6. Deployment (IaC)
Terraform module layout under [`infra/terraform`](../infra/terraform): one shared `refarch-stack` module called by `envs/dev` and `envs/scale`, differing only in values ([ADR-0005](decisions/0005-dev-prod-values-flip.md)). GPU capacity is a Karpenter NodePool, not a static node group.

## 7. Performance results — *the section that makes this a reference, not a brief*

### 7.1 Methodology
Streaming chat completions, temperature 0, fixed prompt across models for comparability. The load generator and the eval both run **in-cluster** as Jobs (no laptop or tunnel in the path), with results written to S3. Quality is scored against machine-checkable gold labels for extraction and an LLM-as-judge for RAG (§7.7). All inputs are synthetic: **Synthea**-derived medical claims/invoices rendered to PDFs across four templates, and **FATURA** commercial invoices — both run through clean, scanned, and degraded-scan tiers. Honest caveat: both are *synthetic families* (shared skeletons), not the full heterogeneity of real-world documents; treat the absolute numbers as relative signal, not a promise about your specific corpus.

### 7.2 Throughput, latency, and cost across the model set `[MEASURED]`
Peak aggregate throughput at 64 concurrent requests, with the actual spot price paid. $/M is output tokens at peak utilization.

| Model | Silicon (instance, pricing) | Peak tok/s | TTFT p50 / p95 (ms) | $/M @ peak |
|---|---|---:|---|---:|
| Qwen2.5-VL-7B | 1× L40S (`g6e.xlarge`, on-demand $1.861/hr) | 2,375 | 105 / 152 | **$0.22** |
| Qwen2.5-VL-72B | 8× A100 (`p4d.24xlarge` spot $11.99/hr) | 2,283 | 132 / 187 | **$1.46** |
| GLM-4.5-Air | 8× H100 (`p5.48xlarge` spot $14.22/hr) | 6,149 | 73 / 95 | **$0.64** |
| Llama-4-Scout | 8× H100 (`p5.48xlarge` spot $14.22/hr) | 3,927 | 139 / 215 | **$1.01** |
| Qwen3-235B-A22B-FP8 | 8× H100 (`p5.48xlarge` spot $14.22/hr) | 3,858 | 88 / 231 | **$1.02** |
| DeepSeek-V3.1 | 8× H100 (`p5.48xlarge` spot $14.22/hr) | 2,274 | 92 / 145 | **$1.74** |

Spot was ~26% of the H100 on-demand list price ($55.04/hr). Numbers are point-in-time spot; re-running later will differ. The same-silicon perf rows (everything on 8× H100) double as a "which GPU should I rent?" answer.

### 7.3 The 7B latency curve `[MEASURED · Qwen2.5-VL-7B · 1× L40S]`
| Concurrency | TTFT p50 / p95 / p99 (ms) | Throughput (tok/s) |
|---|---|---|
| 1 | 30 / 31 / 31 | 49 |
| 8 | 66 / 112 / 112 | 383 |
| 32 | 90 / 116 / 118 | 1,298 |
| 64 | 105 / 152 / 154 | 2,375 |

Single-stream 49 tok/s; aggregate scales to 2,375 tok/s at 64 concurrent with 0 errors and TTFT still ~150 ms — not yet plateaued, so headroom remains.

### 7.4 Extraction quality, by input difficulty `[MEASURED]` (7B/72B) · `[MEASURED · finalizing]` (frontier)
Field-level F1 against gold labels, with Wilson 95% CIs. Headline tier is **scanned-degraded** — skewed, blurred, compressed scans, the way a fax or phone photo actually arrives.

| Model | Medical: clean / scanned / **degraded** | Commercial (FATURA): clean / **degraded** |
|---|---|---|
| Qwen2.5-VL-7B | 96.4 / 97.7 / **93.7** [91.7, 95.2] | 90.2 / **70.6** [64.7, 75.8] |
| Qwen2.5-VL-72B | 96.8 / 98.1 / **96.5** [94.9, 97.6] | 91.0 / **74.5** [68.0, 80.0] |
| Llama-4-Scout | 92.9 / 85.9 / **84.6** | — / **63.7** |
| GLM-4.5-Air | 97.3 (clean digital, text tiers only) | — |
| Qwen3-235B-A22B | 96.7 [95.5, 97.6] (clean digital) | — |
| DeepSeek-V3.1 | `[PENDING]` | `[PENDING]` |

> Frontier-model rows are `[MEASURED · finalizing]`: collected in S3 and being curated into `docs/benchmarks/` (with CIs and per-field detail) before release. The DeepSeek quality row is `[PENDING]` — its reasoning-model serving profile requires harness changes (operational-learnings SE-15, plus reasoning-token budgeting) and is the last run gating publication.

**What the tiers say.** Clean documents are nearly solved even at 7B — paying 10× for the 72B is a statistical tie there. The gains concentrate exactly where the small model fails: on degraded medical, `provider_npi` recovers from **67%→76%** (7B→72B); on degraded commercial, `invoice_number` **41%→50%**, while big bold `total` survives at ~96% regardless. **Scale is a lever, not a cure** — even 72B lands at 74.5% on the hardest commercial tier. The realism axis matters: a single-template, pristine eval reads ~99% F1; representative degraded scans drop the same model to 94.6% (medical) / 70.6% (commercial). We report the hard tier as the headline on purpose.

### 7.5 RAG quality — fixed independent judge `[MEASURED · finalizing]`
Cross-model RAG comparison is only valid with a **fixed, independent judge** — we demonstrated the confound directly: the same pipeline self-judged scored 38.8% under a 7B judge and 30.0% under a 72B judge (stronger judges grade harder; the scores aren't comparable). With a single fixed judge (Qwen2.5-72B), same retrieval and corpus, n=250:

| Model | RAG quality (fixed judge) |
|---|---|
| GLM-4.5-Air | 45.6% [39.5, 51.8] |
| Qwen3-235B-A22B | 36.0% |
| Qwen2.5-VL-72B | 34.0% |
| Llama-4-Scout | 32.0% |
| DeepSeek-V3.1 | `[PENDING]` |

GLM-4.5-Air leads significantly; the rest overlap. These numbers are being verified against the judge-pass artifacts and committed before release. The limiter on the absolute scores is retrieval recall, not generation — improving it is RAG-pipeline work, not a model swap.

### 7.6 Scaling & cold start `[MEASURED · finalizing]`
Karpenter provisions a GPU node for a pending vLLM pod in ~1–2 min (g6e) and consolidates it away ~5 min after the pod scales to zero. Large-MoE weight-load times to be curated from run logs.

## 8. Cost analysis and break-even `[MEASURED]`
Self-host cost is **fixed** (the instance), not per-token. The small model on one L40S at $1.861/hr ≈ **$44.7/day** run 24/7; at the measured peak of 2,375 tok/s it serves ≈ **205 M output tokens/day**, i.e. **$0.22/M at full utilization** ($0.24 / $0.36 / $0.73 at 90 / 60 / 30% utilization). The crossover with a pay-per-token API depends on the API price and your daily volume: against a comparable small-model API at ~$0.30/M output, self-host breaks even at ≈ **150 M output tokens/day** (~73% of this node's capacity). Below that, the API — or Bedrock-in-VPC — is the honest call; above it, sovereign self-host is materially cheaper. Sovereignty and compliance can justify self-host below the crossover independently of cost.

The cross-tier picture is the product of this benchmark: the 72B costs ~6–7× the 7B per token, and buys a few points of accuracy *only on hard documents*. The H100 frontier models land at **$0.64–$1.74/M** at peak on spot — the point being that frontier-scale open models are runnable on hardware anyone can rent by the hour. A Bedrock-in-VPC comparison column (managed alternative, list price, break-even) is planned per [ROADMAP](ROADMAP.md) step 3b.

## 9. Security and compliance posture
Controls map (data residency, audit logging, encryption, tenant isolation) → HIPAA / SOC 2 / EU AI Act. The architecture *supports* compliance; it is not itself a certification. No third-party data egress is the binding invariant.

## 10. Operational learnings
Curated from the running log in [`operational-learnings.md`](operational-learnings.md) (the `[PUBLIC]` entries). The honest accounting of what broke is the credibility signal; each is written so the next engineer who hits it finds the fix.

**Sharp edges worth knowing** — the NVIDIA device plugin needs a node label the chart hard-codes (SE-1); cross-node pod traffic to ports below 1025 is dropped by the default node security group (SE-2); a Kubernetes Service named `vllm` injects a `VLLM_PORT` env var that crashes vLLM (SE-3); single-GPU Deployments must use `Recreate` or the rollout deadlocks (SE-4); a fresh AWS account can't launch spot until the EC2-Spot service-linked role exists (SE-8); and `with psycopg2.connect() as conn` does not close the connection, which exhausts the database pool under load (SE-15).

**What worked** — one stack module across two environments with values-only differences; one vision-language model serving text and vision on a single GPU; embeddings + reranker on CPU keeping the GPU dedicated to the LLM; pgvector instead of a separate vector database at this scale; throughput scaling cleanly to 64 concurrent with no plateau.

**What we'd do differently** — give the vision model its own GPU node in prod; ship the gateway as a pinned ECR image, not pip-at-startup; run the no-egress posture in dev too; right-size resource requests from day one; and never chain a GPU cost-stop to a run completing — make the cluster do the work and a dead-man's switch enforce the spend cap independently (SE-7, SE-9).

## 11. Future variants
Multi-region; on-prem/air-gapped; HIPAA-tightened (BAA); FedRAMP/GovCloud; multi-model LoRA hot-swap; fine-tuning coupling; the Bedrock-in-VPC managed-alternative baseline.

## 12. Reproduce this
Quickstart in [`docs/RUNBOOK.md`](RUNBOOK.md). Eval data is regenerated from the tooling in [`data/`](../data) and [`bench/`](../bench) (the bulk artifacts are gitignored). The pipeline is pinned for reproducibility — Synthea v4.0.0 + seed 1337, the FATURA dataset at a fixed revision, and seeded rendering and degradation — so a clean checkout regenerates the same eval set (see [`data/README.md`](../data/README.md)). The published Q2 figures were generated on the prior Synthea build; regenerating the eval set on the pinned release is the final reproducibility step before release, and the model-level results are reported with confidence intervals that don't hinge on the specific synthetic instances drawn. AWS quota note: G/VT on-demand vCPU ≥ 48 for the dev tier.

## Appendices
- **A. Benchmark raw data** — [`docs/benchmarks/`](benchmarks/) + `bench/reports/runs/` (per-run CSV + `summary.json`).
- **B. IAM policies** — sanitized, from `infra/terraform`.
- **C. Glossary** — vLLM, IRSA, KV-cache, tensor parallelism, quantization, MoE, Wilson CI.
