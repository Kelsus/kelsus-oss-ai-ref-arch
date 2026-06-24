# Security Policy

This repository is a **reference architecture** — Terraform, Helm, application, and
benchmark code meant to be read, adapted, and deployed inside your own AWS account.
It is not a hosted service, and it ships with **no secrets and no real data**: all
benchmark data is synthetic (see [`data/`](data/)).

## Reporting a vulnerability

If you find a security issue in this code — an IAM policy that grants more than it
should, a manifest that weakens isolation, a dependency with a known CVE — please
report it privately:

- **Preferred:** open a private report through GitHub Security Advisories
  (the **Security** tab → **Report a vulnerability**).
- **Or:** reach the Kelsus team via <https://kelsus.com/contact> and mention
  "security — oss-ai-ref-arch".

Please don't open a public issue for a suspected vulnerability until it's been
triaged. We aim to acknowledge a report within five business days and to agree a
disclosure timeline with you.

## Scope

**In scope:** the infrastructure-as-code, Helm charts, serving/gateway code, and the
eval harness in this repository.

**Out of scope:** third-party dependencies (report those upstream, and tell us so we
can pin or patch), and the security of any deployment you stand up from this code —
that runs in your account, under your controls.

## Design intent

The architecture is built around one binding constraint: **no third-party data
egress.** Model weights are pulled once, at build time, into an in-account S3 bucket;
nothing on the serving path leaves the VPC. If you find a path that violates that,
we want to hear about it.
