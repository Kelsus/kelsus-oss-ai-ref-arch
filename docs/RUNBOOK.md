# Runbook — stand up the dev tier

End-to-end: from a clean machine to one inference request served entirely inside the VPC. Target: AWS profile `kelsus-dev`, region `us-east-1`.

## 0. Prerequisites

| Tool | Min version | Install |
|---|---|---|
| AWS CLI v2 | 2.24+ | `brew install awscli` |
| Terraform 1.9+ **or** OpenTofu 1.6+ | — | `brew install opentofu` — the Makefile auto-detects either |
| Helm | 3.15+ | `brew install helm` |
| kubectl | 1.31+ | `brew install kubectl` |
| Python | 3.11+ | for `data/` and `bench/` |

Account readiness (verify for your own profile / account):
- SSO login works: `aws sso login --profile kelsus-dev`
- On-demand **G/VT vCPU quota ≥ 48** (we have 384) — no quota request needed for `g6e.xlarge` (dev) or `g6e.12xlarge` (scale).

## 1. Authenticate

```bash
aws sso login --profile kelsus-dev
export AWS_PROFILE=kelsus-dev AWS_REGION=us-east-1
aws sts get-caller-identity      # confirm your SSO principal / AdministratorAccess
```

## 2. Provision infrastructure (dev tier)

```bash
make tf-dev-init
make tf-dev-plan                 # review: VPC, EKS, Karpenter, S3 model bucket, KMS, observability (GPU provisioned on demand)
make tf-dev-apply
aws eks update-kubeconfig --name kelsus-refarch-dev --region us-east-1
kubectl get nodes                # expect the system nodes Ready; the GPU node appears later, when Karpenter provisions it for vLLM
```

> First apply takes ~15–20 min (EKS control plane). Karpenter and the NVIDIA device plugin come up after the control plane; the GPU node itself is provisioned on demand once vLLM requests a GPU (`make deploy-dev`, or `make gpu-resume` after a pause).

## 3. Seed the model artifact bucket (one-time, build-time egress only)

```bash
make seed-model MODEL=Qwen/Qwen2.5-7B-Instruct   # pulls weights ONCE into the in-account S3 bucket
```

Per [ADR-0001](decisions/0001-sovereign-single-vpc-no-egress.md), this is the only step that reaches the public internet — and it is a build-time operation, never on the serving path.

## 4. Deploy the serving + app layer

```bash
make deploy-dev                  # Helm: vLLM (small model) + embeddings/reranker + gateway
kubectl get pods                 # wait for vllm + embeddings + gateway Ready
```

## 5. Smoke test

```bash
make smoke                       # one chat completion + one RAG query through the internal ALB
```

## 6. Tear down (stop the GPU meter)

```bash
make tf-dev-destroy
```

---

## Scaling to the benchmark tier

```bash
make tf-scale-apply              # envs/scale — Karpenter GPU NodePools (g6e.12xlarge 4× L40S for mid-size; p4d/p5 8× A100/H100 for frontier MoEs)
make deploy-scale MODEL=<candidate>   # FP8/AWQ, TP=4 on L40S or TP=8 on A100/H100
make bench MODEL=<candidate>     # full harness run → bench/reports/runs/<ts>/
```

The only differences from dev are the Terraform env and the model values file ([ADR-0005](decisions/0005-dev-prod-values-flip.md)).
