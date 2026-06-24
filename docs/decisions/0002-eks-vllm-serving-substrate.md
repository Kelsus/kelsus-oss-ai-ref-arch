# ADR-0002 — EKS + vLLM as the serving substrate

**Status:** Accepted · **Date:** 2026-06-05

## Context
We need a serving substrate that is reproducible in a customer account, scales GPU capacity on demand, and exposes an OpenAI-compatible surface so the apps and the benchmark harness are model-portable.

## Decision
- **Orchestration:** Amazon EKS. Karpenter provisions GPU nodes on demand; a small managed node group hosts system/CPU workloads.
- **Inference runtime:** vLLM, for mature PagedAttention, broad open-weight model support, an OpenAI-compatible HTTP surface, and FP8/AWQ quantization + tensor parallelism. Alternatives (SGLang, TensorRT-LLM, TGI) are benchmarked, not defaulted; any bake-off is reported with numbers.
- **Embeddings/reranker:** a separate open-weight embedding + reranker service (BGE-class), so retrieval quality is isolated from generation in the benchmark.

## Consequences
- Apps and harness talk only to an OpenAI-compatible endpoint → swapping the underlying model is a config change, not a code change.
- GPU node groups, the NVIDIA device plugin, and instance-type selection are first-class IaC concerns (see `infra/terraform/modules/gpu-node-group`).
- Kubernetes is a hard dependency for the reference pattern; an ECS/Fargate variant is not in v1.
