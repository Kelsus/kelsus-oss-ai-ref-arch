# Serving layer

The inference + embedding services. Everything exposes an **OpenAI-compatible**
surface so the apps and the benchmark harness are model-portable ([ADR-0002](../docs/decisions/0002-eks-vllm-serving-substrate.md)).

| Component | What | Tier behavior |
|---|---|---|
| **vLLM** | LLM inference, FP8/AWQ, tensor-parallel; loads weights from the in-account S3 bucket | dev: ~8B on 1 GPU · scale: 70B-class, TP=4 |
| **embeddings** | open-weight embedding model (BGE-class) + reranker | retrieval isolated from generation for clean benchmarking |

## seed-model.sh
Functional now. Pulls weights once into S3 (build-time egress per [ADR-0001](../docs/decisions/0001-sovereign-single-vpc-no-egress.md)):
```bash
make seed-model MODEL=Qwen/Qwen2.5-7B-Instruct
```

## What's next (Sprint 2)
- vLLM Helm chart + `infra/helm/vllm-values.yaml` wired to the S3 weights, GPU taint toleration, and the `nvidia.com/gpu` resource request.
- Embedding/reranker deployment.
- The model candidate sweep (DeepSeek V4, Qwen 3.5, GLM-5, Kimi K2.6, Llama 4, Mistral) — one values file per model; the harness picks the [best-on-benchmark](../docs/decisions/0003-best-on-benchmark-model-selection.md) default.
