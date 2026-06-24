# Dev-tier eval-pipeline validation

Purpose: validate the **full scaled eval pipeline** end-to-end on the cheap dev
tier (Qwen2.5-VL-7B, 1× L40S) before spending on the g6e.12xlarge / H100 sweep.
Not a model verdict — a *pipeline* verdict. 2026-06.

**Eval sets:** 400 synthetic invoices + gold (extraction) · 250 LLM-verified,
passage-grounded QA pairs over a 2,943-chunk (2,686-doc) regulated-finance corpus.

| Workload | Score | 95% CI (Wilson) | n |
|---|---:|---:|---:|
| Extraction F1 | **99.0%** | [98.6, 99.3] | 400 invoices / 3,200 fields |
| RAG accuracy (LLM-judge) | **41.2%** | [35.3, 47.4] | 250 questions |

Extraction per-field: patient_name, payer_name, provider_name, provider_npi,
service_date, total_billed, balance_due all **100%**; `num_line_items` **92.2%**.

## What the validation caught (its real value)
1. **Aggregate F1 hid a field artifact.** First read was 86.5% — dragged down by
   `provider_name` at 0.2%. Root cause was *not* the model: the invoice rendered
   the provider as an unlabeled `"Name · Specialty"` header and the 7B returned
   the specialty alone ~⅔ of the time. Fix = render a clearly-labeled `Provider`
   field → 100%. **Lesson: never trust an aggregate without the per-field view and
   a pred-vs-gold spot-check.**
2. **The judge un-faked RAG.** The keyword proxy scored 100% (saturated, useless);
   a real LLM-judge over 250 questions scored 41%. The limiter is retrieval recall
   on a large homogeneous corpus, plus noise from a same-size self-judge. **Levers
   for the sweep: a stronger independent judge, retrieval tuning (hybrid search,
   higher top-k), and harder questions.**
3. `num_line_items` (92%) is a genuine model-discriminating field — counting is
   harder than reading.

## Caveats
Dev 7B VL model; self-model judge; single run. The **scale-tier sweep** produces
the headline numbers with the real candidates and (ideally) an independent judge.
Every number above carries its CI via `bench/stats.py`.
