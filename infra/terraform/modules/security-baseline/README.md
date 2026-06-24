# security-baseline

Account/region detective controls for SOC2 (Trust Services Criteria CC4 & CC7):

| Resource | Control it satisfies |
|----------|----------------------|
| **CloudTrail** (multi-region, log-file validation, → S3 + CloudWatch) | Immutable record of every API call (CC7.2/CC7.3) |
| **GuardDuty** | Continuous threat detection (CC7.2) |
| **AWS Config** (recorder + 5 baseline managed rules) | Resource inventory + config drift detection (CC4.1/CC7.1) |
| **Security Hub** (AWS Foundational Security Best Practices) | Continuous posture scoring (CC4.1) |
| **Audit S3 bucket** (versioned, SSE-S3, TLS-only, public-access blocked, lifecycle) | Tamper-resistant log retention (CC6.1/C1.1) |

VPC flow logs are **not** here — they're cluster-scoped and live on the VPC in
`modules/refarch-stack`.

## Usage

Applied from `envs/account-baseline` (its own state, so it persists when clusters
are destroyed):

```hcl
module "security_baseline" {
  source      = "../../modules/security-baseline"
  name_prefix = "kelsus"
  env         = "account"
}
```

## Important caveats

- **Singletons.** One CloudTrail, one Config recorder, one GuardDuty detector,
  and one Security Hub per account+region. If the account already has any of
  these (e.g. enabled by hand in the console), `apply` will conflict — import the
  existing resource or set the matching `enable_*` toggle to `false`.
- **Regional coverage.** CloudTrail is multi-region from one trail, but
  GuardDuty/Config/Security Hub only cover the region this is applied in. Operate
  in more than one region (dev = us-east-1, scale = us-west-2)? Add a provider
  alias + second module instance, or apply this root once per region.
- **Cost.** All four services bill continuously (Config per-item recorded and
  Security Hub per-check can add up). Leave them on for the audited account; flip
  individual toggles off for throwaway experiment accounts.
- **Encryption.** The audit bucket is SSE-S3. For a customer-managed key, add a
  KMS key with a CloudTrail/Config-compatible key policy and switch the bucket's
  encryption rule to `aws:kms` — left out here to avoid a brittle key policy in
  the reference baseline.
