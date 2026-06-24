# ADR-0005 — Dev and scale tiers differ only in values, never in code

**Status:** Accepted · **Date:** 2026-06-05

## Context
GPU is the dominant cost. We want to iterate cheaply on a small GPU while keeping the path to the full benchmark box a configuration flip — and reproducibility is itself a selling point of a reference architecture.

## Decision
There is exactly **one** set of Terraform modules, Helm charts, and application code. Tiers are expressed only as input values:

| | dev | scale |
|---|---|---|
| GPU node group | `g6e.xlarge` (1× L40S 48 GB) | `g6e.12xlarge` (4× L40S 192 GB) |
| Model | small open-weight (~8B), FP8/AWQ | 70B-class candidates, FP8, TP=4 |
| Replicas / autoscale | minimal | benchmark concurrency profile |
| Terraform env | `infra/terraform/envs/dev` | `infra/terraform/envs/scale` |

Both target AWS profile `kelsus-dev`, region `us-east-1` (the strategy's declared benchmark region).

## Consequences
- "Scale up for the official run" = apply the `scale` env + swap the model values file. No rewrite.
- Any change that works in one tier but not the other (hardcoded sizes, model-specific code paths) is a defect.
- The same parity is what we promise customers: dev/staging/prod differ in values, not architecture.
