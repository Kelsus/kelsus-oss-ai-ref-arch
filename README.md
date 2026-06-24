# Sovereign LLM/RAG Reference Architecture

**A purpose-built, benchmarked pattern for document-intensive AI workloads on AWS — where the data never leaves the customer's VPC.**

This repository is the working build behind the Kelsus public reference architecture. It exists so a platform engineer can read it and decide, in a few minutes, whether self-hosting open-weight models for regulated document workloads is the right call — and reproduce our numbers if they want to.

It is **not** slideware. Every claim in the writeup is backed by a measurement produced by the harness in [`bench/`](bench/), run against the infrastructure defined in [`infra/`](infra/).

> Status: **benchmark complete, publish in progress.** The infrastructure, both apps, and the eval/load harness run end-to-end; the multi-model sweep across L40S / A100 / H100 tiers is done, and measured numbers are backfilling the writeup. Remaining before the public Apache-2.0 release: the final frontier-model quality row, a history-sanitization pass, and validating or correcting the website's pre-published figures. See [Roadmap](#roadmap).

---

## What it proves

The wedge is sovereign open-source AI for **financial-services document workloads** (lending-flavored), with **medical-financial claims** as the adjacent case. The binding constraint across every variant: **no third-party data egress.** Two applications exercise the stack end to end and produce the benchmark numbers:

- **Claims & Invoice Intake** ([`apps/claims-intake`](apps/claims-intake)) — extract → classify → route → reconcile → chase, over synthetic medical claims/invoices. Measures extraction F1, classification accuracy, agentic completion rate, throughput, and $/M-token.
- **Sovereign Document Q&A** ([`apps/sovereign-rag`](apps/sovereign-rag)) — retrieval-augmented Q&A with citations over a public regulated-finance corpus (SEC EDGAR + NIST). Measures RAG answer quality, citation correctness, long-context behavior, and latency.

All data is **fully synthetic** — zero PHI/PII. See [`data/`](data/).

## Architecture at a glance

![Layered architecture of the sovereign LLM/RAG stack inside one VPC: a platform layer (EKS + Karpenter), a data & retrieval layer (S3, Postgres/pgvector, TEI embeddings + reranker), a model-serving layer (vLLM on GPU), the two applications, a guardrails & evaluation layer, and the interface — with security and observability spanning every layer.](docs/architecture-diagram.svg)

Everything runs **inside the customer's AWS account — no third-party data egress.** The request path:
ingest (S3 + in-VPC parsing) → chunk/embed (TEI · BGE embeddings, on CPU) → vector store (Postgres · pgvector) →
retrieve + rerank (hybrid + TEI reranker) → inference (vLLM · open-weight LLM, on GPU) →
guardrails/eval (PII redaction · grounding checks) → application (App 1 / App 2, via the gateway).
Compute is **EKS + Karpenter**-provisioned GPU nodes; IaC is **Terraform**; security is **IAM · KMS (CMK) · private subnets**;
observability is **Prometheus · Grafana · CloudWatch** (latency · cost · retrieval quality).

The same charts and code run at two scales, differing only in values — never in code (see [ADR-0005](docs/decisions/0005-dev-prod-values-flip.md)):

| Tier | GPU — provisioned on demand by Karpenter | Model | Purpose |
|---|---|---|---|
| **dev** | 1× L40S (`g6e.xlarge`) | small open-weight (~7–8B) | plumbing, fast iteration, cheap |
| **scale** | 4× L40S (`g6e.12xlarge`, TP=4) for mid-size · 8× A100/H100 (`p4d`/`p5`, TP=8) for frontier MoEs | 70B → 671B candidates, FP8 / AWQ | the official benchmark numbers |

The GPU node is not a static node group: Karpenter provisions it when the vLLM pod asks for it and consolidates it away when the pod scales to zero (see [ADR-0002](docs/decisions/0002-eks-vllm-serving-substrate.md) and the GPU on/off targets in the [Makefile](Makefile)).

## Serving stack at a glance

> *"Which framework do you use to serve the models — Ollama, KServe, …?"*

**vLLM**, on EKS, behind an internal **OpenAI-compatible** API — all inside the customer's VPC.

| Layer | What we run | Why |
|---|---|---|
| **LLM inference** | **vLLM** (`vllm/vllm-openai`) on EKS GPU nodes | PagedAttention + continuous batching (throughput), tensor-parallelism for multi-GPU (70B–235B+ and frontier MoEs), FP8/AWQ quantization, OpenAI-compatible API |
| **Embeddings + reranker** | **Hugging Face TEI** (BGE) on CPU | keeps the GPU dedicated to the LLM |
| **Vector store** | **Postgres + pgvector** | standard, in-VPC, no separate vector DB |
| **Gateway / orchestration** | FastAPI + plain Kubernetes Deployments + Helm | simple and transparent today |

**Not Ollama, not KServe — and the distinction matters:**
- **Ollama** is a developer / single-user tool (great on a laptop); it is *not* a high-throughput, multi-GPU production server — no continuous batching at scale, no tensor parallelism.
- **KServe** isn't a vLLM alternative; it's a *control-plane* layer (serving CRDs, autoscaling, canaries) that runs **on top of** a runtime like vLLM. We use plain Deployments + Helm today; KServe / Ray Serve is a reasonable *future* option for the autoscaling / multi-model layer — with vLLM still underneath.

vLLM is our **default, not a mandate**: we also benchmark **SGLang, TensorRT-LLM, and TGI**, and everything sits behind that OpenAI-compatible API so the runtime is swappable — see [ADR-0002](docs/decisions/0002-eks-vllm-serving-substrate.md).

## Repository layout

| Path | What's in it |
|---|---|
| [`infra/terraform`](infra/terraform) | VPC, EKS, GPU node group, vector store, model bucket, observability — `envs/dev` and `envs/scale` |
| [`infra/helm`](infra/helm) | Helm values for vLLM, embeddings, gateway, observability |
| [`serving`](serving) | vLLM + embedding/reranker server configs (model, quantization, tensor-parallel) |
| [`apps`](apps) | The two benchmark apps + the FastAPI gateway (guardrails, PII redaction) |
| [`data`](data) | Synthetic data generators: Synthea, CMS DE-SynPUF, FATURA, SEC/NIST corpus, gold labels |
| [`bench`](bench) | Eval + load harness — mirrors the `kelsus/oss-llm-index` layout so the same harness feeds the public Index |
| [`docs`](docs) | The public writeup (`architecture.md`), decision records, and published benchmark results |

## Quickstart

See the [**RUNBOOK**](docs/RUNBOOK.md) for the full deploy. The short version:

```bash
aws sso login --profile kelsus-dev
make tf-dev-apply          # VPC + EKS + Karpenter in kelsus-dev / us-east-1 (GPU provisioned on demand)
make deploy-dev            # vLLM (small model) + embeddings/reranker + gateway via Helm
make smoke                 # one request end-to-end, never leaving the VPC
```

## Roadmap

Full detail in [docs/ROADMAP.md](docs/ROADMAP.md).

- [x] Sprint 0 — repo + IaC foundation + ADRs + runbook
- [x] Sprint 1 — synthetic data pipeline (Synthea → CMS-1500/EOB; FATURA; SEC/NIST corpus; gold labels)
- [x] Sprint 2 — both apps working end-to-end at dev scale
- [x] Sprint 3 — `bench/` harness emits F1, RAG quality, TTFT/p95, throughput, $/M-token
- [x] Sprint 4 — scale-tier multi-model sweep across L40S / A100 / H100 *(final frontier-model quality row in progress)*
- [ ] Sprint 5 — measured numbers backfill the writeup; sanitization; public Apache-2.0 release *(in progress)*
- [ ] Phase 6 — **Living Benchmark Site**: a designed public microsite (linked from kelsus.com) that publishes the benchmark results and **updates itself when benchmarks run**

## License

Apache-2.0 (intended for public release). See [LICENSE](LICENSE).
