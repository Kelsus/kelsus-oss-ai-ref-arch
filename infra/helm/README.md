# Helm — in-cluster components

Installed by `deploy.sh` **after** the cluster exists. This split (infra in
Terraform, in-cluster apps in Helm) keeps Terraform's provider graph simple.

| Chart | Status | Notes |
|---|---|---|
| nvidia-device-plugin | **working** | exposes `nvidia.com/gpu`; tolerates the GPU node taint |
| vllm | Sprint 2 | values in `vllm-values.yaml`; loads weights from S3 |
| embeddings + reranker | Sprint 2 | BGE-class |
| gateway | Sprint 2 | FastAPI; PII redaction + grounding guards; internal ALB |
| observability (kube-prometheus-stack) | Sprint 3 | Prometheus + Grafana; scrapes vLLM `/metrics` |

```bash
make deploy-dev                    # device plugin now; serving as charts land
make deploy-scale MODEL=<candidate>
```
