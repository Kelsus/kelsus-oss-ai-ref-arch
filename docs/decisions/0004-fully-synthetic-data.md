# ADR-0004 — Fully synthetic data, zero PHI/PII

**Status:** Accepted · **Date:** 2026-06-05

## Context
The proof workload is a rebuild of a medical-billing/claims document workflow. The originating business is cavalier about HIPAA; Kelsus must not inherit that exposure. We need realistic document volume and **ground-truth labels** to measure extraction and RAG accuracy honestly.

## Decision
All data is generated synthetically; **no real PHI/PII ever enters the system.**

| Source | Role |
|---|---|
| **Synthea** (MITRE) | Synthetic patients with claim costs + CPT/ICD/HCPCS codes; rendered into CMS-1500 / UB-04 / EOB / medical-invoice PDFs. The healthcare-invoice generator. |
| **CMS DE-SynPUF** | Synthetic Medicare claims at volume (inpatient/outpatient/carrier/PDE) for the reconcile + "chase" workload. |
| **FATURA** | 10k labeled synthetic commercial invoices, 50 layouts, 24 field classes — layout diversity with ground truth. |
| **SEC EDGAR (EX-10 lending agreements) + NIST** | Public-domain regulated-finance corpus for the RAG app. |

Gold labels are emitted **alongside** the generated data so every accuracy metric is measured against truth, not estimated.

## Consequences
- The case study can be published without a HIPAA BAA or de-identification review.
- Synthea costs are a simplified model of real-world pricing; reconciliation tasks are calibrated to that, and the limitation is disclosed in the writeup.
- A future "real Varent sample" path remains possible only behind explicit sign-off + de-identification; it is not in v1.
