# Infrastructure (Terraform)

Two environments, one set of building blocks ([ADR-0005](../../docs/decisions/0005-dev-prod-values-flip.md)):

```
infra/terraform/
  modules/
    model-artifact-bucket/   # S3 + KMS CMK for model weights (ours)
  envs/
    dev/                     # 1× g6e.xlarge GPU node group — cheap iteration
    scale/                   # g6e.12xlarge (4× L40S) — benchmark runs
```

**VPC and EKS use audited community modules** (`terraform-aws-modules/vpc`, `terraform-aws-modules/eks`) rather than hand-rolled equivalents — reusing well-reviewed infrastructure is itself the right call for a security-first reference, and it keeps the diff readers have to trust small. The bespoke pieces (the model artifact bucket, the GPU node group config, the no-egress posture, IRSA wiring) are where our opinions live.

In-cluster components (NVIDIA device plugin, vLLM, embeddings, gateway, observability) are installed by Helm *after* the cluster exists — see [`infra/helm`](../helm) and the [runbook](../../docs/RUNBOOK.md). This split keeps Terraform's provider graph simple and avoids the kubernetes/helm provider chicken-and-egg on first apply.

## Sovereign networking posture
- Private subnets host all workloads.
- `enable_nat_gateway` defaults **on** in `dev` (convenience) and **off** in `scale`/prod, where reachability to AWS services is provided exclusively by **VPC endpoints** (S3 gateway + ECR/STS/Logs/EKS interface endpoints). That is the no-third-party-egress posture from [ADR-0001](../../docs/decisions/0001-sovereign-single-vpc-no-egress.md); dev keeps NAT only to speed iteration.

## State
Local state for now (Sprint 0). An S3 + DynamoDB remote backend is added before any shared/CI use — see the commented `backend` block in `envs/dev/versions.tf`.
