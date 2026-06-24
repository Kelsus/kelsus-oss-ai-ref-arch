# Contributing

This repository exists to be read and pressure-tested. Issues, questions, and pull
requests are all welcome — including "this IAM policy is broader than it needs to be"
and "the runbook step fails on my Terraform version."

## Ways to contribute

- **Found something wrong or unclear?** Open an issue with the specifics — the exact
  command, the tier (dev/scale), and the error string if there is one.
- **Curious about a design choice?** The decision records in
  [`docs/decisions/`](docs/decisions/) explain the major ones. If a choice isn't
  covered there, open a question issue and ask.
- **Want to propose a change?** Open a pull request. For anything substantial, open an
  issue first so we can agree on the approach before you spend time on it.

## Local checks before you open a PR

The same checks run in CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml));
run them locally first:

```bash
make fmt                                        # format all Terraform
make validate                                   # validate both envs (dev + scale)
python3 -m py_compile $(git ls-files '*.py')    # Python parses
bash -n $(git ls-files '*.sh')                  # shell scripts parse
```

The Makefile auto-detects Terraform or OpenTofu — you don't need both.

## Ground rules

- **No secrets, ever.** No account IDs, ARNs, access keys, kubeconfigs, or `.tfvars`.
  The [`.gitignore`](.gitignore) blocks the usual suspects; keep it that way.
- **No real data.** All benchmark data is synthetic and regenerated from the tools in
  [`data/`](data/). Don't commit generated artifacts or anything derived from real
  documents.
- **Keep dev and scale in lockstep.** The two environments differ only in values,
  never in code (see [ADR-0005](docs/decisions/0005-dev-prod-values-flip.md)). A change
  to one usually belongs in the shared module.
- **Match the surrounding code,** keep PRs small and focused, and explain the *why* in
  the description.

## License

By contributing, you agree that your contributions are licensed under the project's
[Apache-2.0](LICENSE) license.
