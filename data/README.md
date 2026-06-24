# Data — fully synthetic, zero PHI/PII

Per [ADR-0004](../docs/decisions/0004-fully-synthetic-data.md), nothing here is real patient or customer data. Every source is synthetic or public-domain, and gold labels are emitted alongside the documents so accuracy is **measured against truth**, not estimated.

| Dir | Source | Produces | Used by |
|---|---|---|---|
| [`synthea/`](synthea) | **Synthea** (MITRE) | Synthetic patients with claim costs + CPT/ICD/HCPCS → rendered CMS-1500 / EOB / medical-invoice PDFs | App 1 (claims intake) |
| [`desynpuf/`](desynpuf) | **CMS DE-SynPUF** | Synthetic Medicare claims at volume (inpatient/outpatient/carrier/PDE) | App 1 (reconcile + chase) |
| [`fatura/`](fatura) | **FATURA** | 10k labeled synthetic commercial invoices, 50 layouts, 24 field classes | App 1 (extraction F1 with ground truth) |
| [`corpus/`](corpus) | **SEC EDGAR + NIST** | Public regulated-finance documents (EX-10 lending agreements, 10-Ks, NIST pubs) | App 2 (sovereign RAG) |
| [`gold/`](gold) | generated | Ground-truth field labels + Q/A pairs keyed to the above | `bench/` scoring |

## Quickstart
```bash
make data-synthea     # synthetic patients/claims -> CMS-1500/EOB PDFs
make data-fatura      # download FATURA labeled invoices
make data-corpus      # build the SEC + NIST RAG corpus
```

Generated bulk artifacts (PDFs, parquet, raw downloads) are gitignored — they are reproducible from these scripts. Only the generators and small label manifests are tracked.

## Reproducibility pins

The eval set is deterministic given these pins, so a clean checkout regenerates the same documents and gold:

| Source of variation | Pin |
|---|---|
| Synthea version | **v4.0.0** release jar — not `master-branch-latest` (a rolling tag drifts over time) · `synthea/generate.sh` |
| Synthea seed | **1337** · `synthea/generate.sh` |
| Field order & template choice | seeded per item index · `synthea/render_forms.py` |
| Scan degradation (skew/blur/noise) | seeded per item index · `synthea/degrade.py` |
| FATURA dataset | revision `bcbb2fbb3c4701b87f5659ecbfbc55ad695aac21` · `fatura/build.py` |

Everything downstream of the generators seeds off the item index, so identical Synthea / FATURA inputs yield byte-identical eval images and gold.

### Regenerate the full eval set

```bash
make data-synthea                          # Synthea v4.0.0, seed 1337 -> patient/claims CSV
python3 data/synthea/render_forms.py 400   # CSV -> 400 medical-invoice PDFs (4 templates) + gold
python3 data/synthea/build_eval.py         # tier clean/scanned/degraded -> bench/quality/eval_manifest.jsonl
make data-fatura                           # FATURA (pinned revision) -> commercial images + gold
make data-corpus                           # RAG corpus (public Federal Register / SEC sources)
```

**On the Q2 figures:** they were generated on the Synthea `master-branch` build available at run time; the version pins above were added afterward. Regenerating the eval set on the pinned v4.0.0 release is the final reproducibility step before public release. Model-level results carry confidence intervals and don't hinge on which specific synthetic patients are drawn, but a byte-for-byte reproduction needs the pinned version.

## Why healthcare is the *easiest* to source cleanly
Real medical invoices are radioactive (PHI/HIPAA). Synthea sidesteps that entirely: it models a full synthetic patient population — encounters, procedures, costs, payer coverage, CPT/ICD/HCPCS codes — with no real person behind any record. We render those records into the standard claim/invoice forms (CMS-1500, UB-04, EOB), giving us realistic healthcare "invoices" at any volume, with the ground-truth fields known by construction.
