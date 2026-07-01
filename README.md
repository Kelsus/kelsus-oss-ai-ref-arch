# Sovereign LLM/RAG Reference Architecture

**A benchmarked reference architecture for document-heavy AI workloads on AWS, where the data never leaves the customer's account.**

This repository is the working build behind the Kelsus public reference architecture. A platform engineer can read it, decide whether self-hosting open-weight models for regulated document workloads fits their case, and reproduce the numbers.

Every claim in the writeup comes from a measurement produced by the harness in [`bench/`](bench/), run against the infrastructure in [`infra/`](infra/).

> Status: **complete.** The infrastructure, both applications, and the eval and load harness run end to end. The same-weights benchmark is finished: each current-generation open-weight model in the lineup was measured self-hosted on our vLLM stack, on Amazon Bedrock, and against the frontier (Claude Opus 4.8 and Sonnet 4.6). The headline results are in [Benchmark results](#benchmark-results); the per-model tables, methods, and confidence intervals are in [`docs/benchmarks/`](docs/benchmarks/).

---

## What it covers

This targets sovereign open-source AI for financial-services document workloads, with medical-financial claims as the adjacent case. The constraint across all of them is no third-party data egress. Two applications exercise the stack end to end and produce the benchmark numbers:

- **Claims & Invoice Intake** ([`apps/claims-intake`](apps/claims-intake)): extract, classify, route, reconcile, and chase, over synthetic medical claims and invoices. Measures extraction F1, classification accuracy, agentic completion rate, throughput, and $/M-token.
- **Sovereign Document Q&A** ([`apps/sovereign-rag`](apps/sovereign-rag)): retrieval-augmented Q&A with citations over a public regulated-finance corpus. Measures RAG answer quality, citation correctness, long-context behavior, and latency.

All data is synthetic, with zero PHI or PII. See [`data/`](data/).

## Architecture

![Layered architecture of the sovereign LLM/RAG stack inside one VPC: a platform layer (EKS and Karpenter), a data and retrieval layer (S3, Postgres/pgvector, TEI embeddings and reranker), a model-serving layer (vLLM on GPU), the two applications, a guardrails and evaluation layer, and the interface, with security and observability spanning every layer.](docs/architecture-diagram.svg)

Everything runs inside the customer's AWS account, with no third-party data egress. The request path is: ingest (S3 and in-VPC parsing), chunk and embed (TEI with BGE embeddings, on CPU), vector store (Postgres with pgvector), retrieve and rerank (hybrid plus TEI reranker), inference (vLLM serving the open-weight LLM, on GPU), guardrails and eval (PII redaction, grounding checks), and the application (App 1 or App 2, via the gateway). Compute is EKS with Karpenter-provisioned GPU nodes, IaC is Terraform, security is IAM with KMS (CMK) and private subnets, and observability is Prometheus, Grafana, and CloudWatch (latency, cost, retrieval quality).

The same charts and code run at two scales, with different values and identical code (see [ADR-0005](docs/decisions/0005-dev-prod-values-flip.md)):

| Tier | GPU, provisioned on demand by Karpenter | Model | Purpose |
|---|---|---|---|
| **dev** | 1× L40S (`g6e.xlarge`) | small open-weight (~7-8B) | plumbing, fast iteration, low cost |
| **scale** | 4× L40S (`g6e.12xlarge`, TP=4) for mid-size, 8× A100/H100/H200 (`p4d`/`p5`/`p5e`, TP=8) for the large MoEs | 70B to ~1T candidates, FP8 / INT4 | the official benchmark numbers |

Karpenter provisions the GPU node when the vLLM pod asks for it, and removes it when the pod scales to zero (see [ADR-0002](docs/decisions/0002-eks-vllm-serving-substrate.md) and the GPU on/off targets in the [Makefile](Makefile)).

## Serving stack

> *"Which framework do you use to serve the models, Ollama, KServe, ...?"*

vLLM, on EKS, behind an internal OpenAI-compatible API, all inside the customer's VPC.

| Layer | What we run | Why |
|---|---|---|
| **LLM inference** | **vLLM** (`vllm/vllm-openai`) on EKS GPU nodes | PagedAttention and continuous batching for throughput, tensor parallelism for multi-GPU (70B to 235B and the large MoEs), FP8/INT4 quantization, OpenAI-compatible API |
| **Embeddings + reranker** | **Hugging Face TEI** (BGE) on CPU | keeps the GPU dedicated to the LLM |
| **Vector store** | **Postgres + pgvector** | standard, in-VPC, with no separate vector database |
| **Gateway / orchestration** | FastAPI with plain Kubernetes Deployments and Helm | simple and transparent today |

Why vLLM, and why not Ollama or KServe:
- **Ollama** is a developer and single-user tool, good on a laptop. It does not do continuous batching at scale or tensor parallelism, so it does not serve as a high-throughput, multi-GPU production server.
- **KServe** is a control-plane layer (serving CRDs, autoscaling, canaries) that runs on top of a runtime like vLLM, so it complements vLLM rather than replacing it. We use plain Deployments and Helm today; KServe or Ray Serve is a reasonable future option for the autoscaling and multi-model layer, with vLLM still underneath.

vLLM is the default. We also benchmark SGLang, TensorRT-LLM, and TGI, and everything sits behind the OpenAI-compatible API, so the runtime is swappable (see [ADR-0002](docs/decisions/0002-eks-vllm-serving-substrate.md)).

## Repository layout

| Path | What's in it |
|---|---|
| [`infra/terraform`](infra/terraform) | VPC, EKS, GPU node pools, vector store, model bucket, observability. `envs/dev` and `envs/scale` |
| [`infra/helm`](infra/helm) | Helm values for vLLM, embeddings, gateway, observability |
| [`serving`](serving) | vLLM and embedding/reranker server configs (model, quantization, tensor-parallel) |
| [`apps`](apps) | The two benchmark apps and the FastAPI gateway (guardrails, PII redaction) |
| [`data`](data) | Synthetic data generators: Synthea, CMS DE-SynPUF, FATURA, the regulated-finance corpus, gold labels |
| [`bench`](bench) | Eval and load harness. Mirrors the `kelsus/oss-llm-index` layout so the same harness feeds the public Index |
| [`docs`](docs) | The writeup (`architecture.md`), decision records, and the benchmark results |

## Quickstart

See the [**RUNBOOK**](docs/RUNBOOK.md) for the full deploy. The short version:

```bash
aws sso login --profile kelsus-dev
make tf-dev-apply          # VPC + EKS + Karpenter in your dev account (GPU provisioned on demand)
make deploy-dev            # vLLM (small model) + embeddings/reranker + gateway via Helm
make smoke                 # one request end-to-end, never leaving the VPC
```

## Benchmark results

The question this answers is what you give up by self-hosting an open-weight model instead of calling Amazon Bedrock or a frontier model. We measured it on one workload and one harness, holding everything constant except the substrate: the same models served on our vLLM stack, on Bedrock, and (for the frontier) on Anthropic's API. The lineup is the current generation of open weights, Qwen3-VL-235B, Llama-4-Scout, GLM-4.7, Kimi-K2.5, DeepSeek-V3.2, GLM-5.2, and DeepSeek-V4-Pro (plus self-hosted-only Ornith-1.0-397B and Nemotron-3-Ultra-550B), measured beside Claude Opus 4.8 and Sonnet 4.6.

Three results held across both document extraction and retrieval:

- **The substrate does not change quality.** The same weights scored the same whether we served them or Bedrock did, inside the confidence intervals, on both extraction and RAG. Self-hosting reproduces the managed provider's output on identical inputs.
- **The frontier's quality lead is confined to hard *commercial* document extraction.** On degraded commercial invoices (skewed, blurred, compressed, varied layouts), Opus leads the best open model by about ten points. On medical claims the whole lineup saturates near 99–100% once a gold-data bug is corrected (the `provider_npi` field had stored a UUID instead of a 10-digit NPI; see [the comparison doc](docs/benchmarks/same-weights-comparison.md), Caveat 5), so medical extraction is not a differentiator. On grounded retrieval QA the open models tie the frontier, and that lead does not carry over.
- **Self-hosting costs less per token at high utilization for most of the lineup.** GLM-4.7 runs about $1.27 per million output tokens self-hosted against $2.20 on Bedrock, and the frontier models cost 8 to 38 times the open-weight options. Reasoning models are the exception: their lower throughput makes self-hosting more expensive than Bedrock.

The full writeup, per-model tables, methods, and confidence intervals are in [`docs/benchmarks/`](docs/benchmarks/).

## Roadmap

Full detail in [docs/ROADMAP.md](docs/ROADMAP.md).

- [x] Sprint 0: repo and IaC foundation, ADRs, runbook
- [x] Sprint 1: synthetic data pipeline (Synthea to CMS-1500/EOB; FATURA; regulated-finance corpus; gold labels)
- [x] Sprint 2: both apps working end-to-end at dev scale
- [x] Sprint 3: `bench/` harness emits F1, RAG quality, TTFT/p95, throughput, $/M-token
- [x] Sprint 4: scale-tier multi-model sweep across L40S / A100 / H100 / H200
- [x] Sprint 5: same-weights comparison against Bedrock and the frontier; writeup; public Apache-2.0 release
- [ ] Multi-cloud ports (Azure, GCP) and benchmarks on fine-tuned models *(in progress)*
- [ ] Living Benchmark Site: a public microsite (linked from kelsus.com) that updates as new benchmarks run

## License

Apache-2.0. See [LICENSE](LICENSE).
