# Gold labels — ground truth for scoring

Machine-checkable ground truth, emitted **alongside** the generated documents so
accuracy is measured against truth, not estimated (ADR-0004).

| Path | Produced by | Consumed by |
|---|---|---|
| `claims/<claim_id>.json` | `data/synthea/render_forms.py` | App 1 extraction F1 |
| `qa/<id>.json` *(Sprint 1)* | `data/corpus/build.py` | App 2 RAG grounding |

Each `claims/*.json` is the exact record used to render the matching
`data/synthea/output/forms/<claim_id>.pdf`, with fields: patient, payer,
provider (+NPI), service date, diagnoses, line items (code/units/charge), and
totals (billed/paid/balance).

Generated JSON is gitignored (reproducible via `make data-synthea` →
`render_forms.py`); only this README is tracked.
