# ADR-0001 — Single-VPC sovereign deployment, no third-party data egress

**Status:** Accepted · **Date:** 2026-06-05

## Context
The target buyer is a regulated financial-services (and adjacent medical-financial) enterprise for whom transferring document content to a third-party API creates compliance, contractual, or board-level risk. The differentiator of the entire offering is custody: the data does not leave the customer's perimeter.

## Decision
The reference deployment runs entirely inside a single customer-controlled AWS VPC. There is **no public ingress and no public egress** except an explicit allow-list of in-account AWS endpoints reached over VPC endpoints (S3, ECR, CloudWatch, STS). Model weights, embeddings, vector store, inference, and applications all live in-account. Ingress to applications is via an **internal** ALB only.

## Consequences
- Every component must have an in-VPC or VPC-endpoint path; anything requiring public internet (e.g., pulling model weights from Hugging Face) happens **once, at build/seed time**, into the in-account S3 artifact bucket — never on the serving path.
- Multi-region/air-gapped variants are explicitly out of scope for v1 (future variants).
- This constraint is the test every future change must pass: *does this introduce third-party data egress?* If yes, it does not ship in the sovereign pattern.
