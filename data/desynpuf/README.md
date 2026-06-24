# CMS DE-SynPUF — synthetic Medicare claims at volume

Synthetic (not real) Medicare claims derived from a 5% sample, fully de-identified
and released by CMS for exactly this kind of development. Five file types:
Beneficiary Summary, Inpatient, Outpatient, Carrier, and Prescription Drug Events.

Used by **App 1** for the reconcile + "chase" workload, where we need realistic
claim *volume* and payer/provider structure rather than rendered forms.

## Get it
- Landing page: https://www.cms.gov/data-research/statistics-trends-and-reports/medicare-claims-synthetic-public-use-files
- DE-SynPUF (2008–2010), 20 samples: https://www.cms.gov/data-research/statistics-trends-and-reports/medicare-claims-synthetic-public-use-files/cms-2008-2010-data-entrepreneurs-synthetic-public-use-file-de-synpuf
- Mirror in OMOP CDM on AWS Open Data: https://registry.opendata.aws/cmsdesynpuf-omop/

Start with **Sample 1** (a 0.25% slice) — it's enough for development. Codes are
ICD-9 in this vintage; map to ICD-10 where the workflow needs current codes, and
document the mapping. A `download.py` (Sprint 1) will pull Sample 1 and stage the
carrier/outpatient claims for the reconciliation tasks.
