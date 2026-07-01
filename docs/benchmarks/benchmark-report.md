# Sovereign, managed, or frontier? A controlled benchmark of open-weight and frontier LLMs on enterprise document tasks

*Kelsus OSS LLM reference architecture — benchmark report. Synthetic/public data only ([ADR-0004](../decisions/0004-fully-synthetic-data.md)). Results current as of 2026-06-22; see [same-weights-comparison.md](same-weights-comparison.md) for the prior narrative writeup this supersedes.*

---

## Abstract

Enterprises evaluating large language models for document workloads face a three-way choice: **self-host** open weights on rented GPUs, call the **same weights on a managed provider** (AWS Bedrock), or pay for a **frontier** model. We built a single workload, a single serving/scoring harness, and held everything constant except the substrate, so that A→B→C comparisons isolate *who runs the model and on what*. The workload is the enterprise document pipeline our reference architecture targets: structured field extraction from invoices/claims (520 documents, deterministic per-field F1 against ground truth) and retrieval-augmented question answering over a 2,686-document financial-regulation corpus (250 questions, scored by an independent fixed judge). We evaluated six open-weight families (Qwen3-VL-235B, Llama-4-Scout, GLM-4.7, Kimi-K2.5, DeepSeek-V3.2, GLM-5/5.2) and two frontier models (Claude Opus 4.8, Sonnet 4.6) across self-hosted vLLM, Bedrock, and direct-API substrates, measuring quality, latency, and cost per model. Three findings hold: (1) **substrate-invariance** — the same weights produce the same quality whether we serve them or Bedrock does, within confidence intervals, on every axis; (2) the **frontier quality premium is confined to extraction on degraded *commercial* document layouts** (on medical claims the whole lineup saturates near 99–100% once a `provider_npi` gold-data bug is corrected — §2.3) and does *not* transfer to grounded RAG, where an open-model cluster ties the frontier; (3) **self-hosting wins on cost-per-token at high utilization for most of the lineup**, with reasoning models the exception. We conclude with an all-around recommendation and a situational decision guide.

---

## 1. Objective

Buyers ask a concrete question: *"How much do I give up by self-hosting an open-weight model instead of just calling Bedrock or just using the frontier?"* Answering it requires holding the model and the workload fixed and varying only the substrate. We test one hypothesis explicitly — **substrate-invariance**: identical weights yield identical task quality regardless of who serves them — and, having established that the harness is calibrated, we quantify the quality, speed, and cost deltas that actually distinguish the three options.

---

## 2. Methods

### 2.1 Experimental design

One workload, one harness, three substrates. Every request — self-hosted, managed, or frontier — routes through the same gateway, which performs identical retrieval, prompting, vision routing, and scoring. The only manipulated variable is the substrate:

| Layer | Substrate | What it isolates |
|---|---|---|
| **A — Sovereign self-hosted** | our vLLM on rented GPUs, in-VPC | open weights re-run on our stack |
| **B — Managed** | the *same* family/checkpoint on AWS Bedrock | our serving vs the provider's, same weights |
| **C — Frontier** | Claude Opus 4.8 / Sonnet 4.6, via Bedrock **and** direct Anthropic API | the ceiling, inside AWS's walls and out |

A vs B is the calibration check (same weights, two operators). B vs C is the open-vs-frontier gap. The frontier's Bedrock-vs-direct pair additionally isolates the provider substrate at fixed weights.

### 2.2 Models under test

| Family | Params | Self-host precision / hardware | Managed substrate |
|---|--:|---|---|
| Qwen3-VL-235B | 235B | FP8, 8×H200 (TP=8) | Bedrock |
| Llama-4-Scout | 109B (MoE) | BF16, 8×H100 (TP=8) — *exact-weights pair* | Bedrock |
| GLM-4.7 | — | FP8, 8×H100 (TP=8) | Bedrock |
| Kimi-K2.5 | — | INT4 (native), 8×H200 (TP=8) | Bedrock |
| DeepSeek-V3.2 | — | FP8 (official), 8×H200 (TP=8) | Bedrock |
| GLM-5 / GLM-5.2 | 745B / 753B | FP8, 8×H200 (TP=8) | Bedrock (GLM-5) |
| Claude Opus 4.8 *(frontier)* | — | — | Bedrock + Anthropic direct |
| Claude Sonnet 4.6 *(frontier)* | — | — | Bedrock + Anthropic direct |

All self-hosted open models served **single-box on one 8×H200 (or 8×H100) node** under a pinned stable vLLM (v0.23.0). Llama-4-Scout is the strict same-weights pair (the identical published checkpoint runs on both our stack and Bedrock); GLM-5/5.2 is a **family** pair, not same-weights (Bedrock serves GLM-5, we self-host the half-version-newer GLM-5.2) — treat that row as a family comparison, not a calibration check.

### 2.3 Task 1 — Structured document extraction

**Goal.** Given a rendered invoice/claim, return the key fields as JSON, scored field-by-field against deterministic ground truth.

**Data.** Two synthetic corpora with machine-emitted gold labels, each rendered at increasing real-world difficulty:

- **Medical claims (Synthea, MITRE):** 400 documents → CMS-1500 / EOB / medical-invoice layouts. Eight scored fields: `patient_name, payer_name, provider_name, provider_npi, service_date, total_billed, balance_due, num_line_items`. Three difficulty tiers (134 / 133 / 133): **clean-digital** (PDF with a text layer), **scanned-clean** (rendered to image, no text layer), **scanned-degraded** (image + scan wear).
- **Commercial invoices (FATURA):** 120 documents, real invoice *layouts* with synthetic content, 50 templates. Five scored fields: `invoice_number, invoice_date, due_date, total, buyer_name`. Two tiers (60 / 60): **scanned-clean**, **scanned-degraded**.

*Example commercial gold* (`data/fatura/gold/fatura-1043.json`):
```json
{"invoice_number": "3Y4M9d-047", "invoice_date": "31-Oct-2005",
 "due_date": "26-Oct-2001", "total": "866.74", "buyer_name": "Brandon Williams"}
```
A sample rendered invoice the model actually sees: `data/fatura/output/fatura-6437.png` (scanned-clean tier).

**Degradation (what makes the benchmark representative, not rigged).** `scanned-degraded` images are produced deterministically per seed (`data/synthea/degrade.py`): random skew (rotate ±2°×level), Gaussian blur (0.6×level), a downscale→upscale resolution loss, JPEG-quality reduction, and sensor noise. A degraded image has **no text layer**, so it forces the *vision* path (reading pixels) rather than a pristine digital parse. Text-only models (Kimi, DeepSeek, GLM-4.7, GLM-5.2) have no vision path and are therefore evaluated only on the `clean-digital` tier; vision models (Qwen3-VL, Llama-4-Scout, Opus, Sonnet) run all image tiers.

**Prompt** (verbatim, medical track; temperature 0, JSON-object mode, `max_tokens` 400):
```
System: You extract structured data from a medical claim/invoice. Return ONLY a
JSON object with exactly these keys: patient_name, payer_name, provider_name,
provider_npi, service_date (YYYY-MM-DD), total_billed (number), balance_due
(number), num_line_items (integer). Use null for any field not present.
User:   INVOICE:\n<document text or image>
```

**Scoring (deterministic, per field).** A field counts as correct under type-appropriate matching: money within $0.01; counts as exact integers; names by alpha-token containment (so `"Dr. Rhett Smith · Cardiology"` matches gold `"Rhett Smith"` — the rendered "Name · Specialty" and Synthea's numeric suffixes are not extraction errors); identifiers/dates by normalized containment. **F1 = correct fields / (documents × fields)**, reported per tier with a Wilson 95% confidence interval. The **headline number is the hardest tier** (`scanned-degraded`, abbreviated *med-deg* / *com-deg*), because that is what production scanned intake looks like.

**Gold correction (2026-06-30).** The medical gold initially stored `provider_npi` as the provider's Synthea UUID `Id` (a 36-char hex string), not a 10-digit NPI — `render_forms.py` used the provider `Id` as a stand-in, so every invoice rendered a UUID in the NPI field. This suppressed medical extraction two ways: reasoning models declined to emit a UUID *as* an NPI (returning null), and on degraded scans the long UUID is hard to OCR even for the frontier. Fixed by synthesizing a deterministic Luhn-valid NPI from the provider `Id` (400/400 gold regenerated, claim-id set unchanged, `forms-scan` re-rasterized); **all 21 models were re-scored on the corrected gold.** Effect: `provider_npi` rose to ~100% and medical extraction saturates 97–100% across the lineup (the medical numbers in §3 are the corrected values). The scorer now persists raw per-field misses (`bench/quality/score.py`) so any future low field is auditable. Commercial (FATURA — no NPI field) and RAG (gold untouched) are unaffected.

### 2.4 Task 2 — Retrieval-augmented QA (sovereign RAG)

**Goal.** Answer a financial-regulation question grounded *only* in retrieved passages, with citations or an explicit refusal.

**Corpus & pipeline (all in-VPC).** 2,686 public US financial-regulation documents (CFPB consumer-finance reports and Federal Register rules — e.g. the *Consumer Credit Card Market Report*, CARD Act notices). Ingestion: chunk (1,400 chars, 200 overlap) → embed (TEI / BGE, 768-dim) → store in Postgres + pgvector. Query: embed → cosine top-5 → prompt → cited answer.

*Example corpus document* (`data/corpus/seed/docs.jsonl`): *"Consumer Credit Card Market Report of the Consumer Financial Protection Bureau, 2025"* (source: federalregister.gov). *Example evaluation question* (`bench/quality/rag_gold.json`, n=250): **Q:** "What act requires the CFPB to review the consumer credit card market?" **Reference:** "The Credit Card Accountability Responsibility and Disclosure Act of 2009 (CARD Act)…"

**Prompt** (verbatim; temperature 0, top-5 context, `max_tokens` 400):
```
System: You answer strictly from the provided CONTEXT about financial regulation.
Cite the sources you use with bracketed numbers like [1]. If the answer is not in
the context, say exactly: "I don't know based on the provided documents."
User:   CONTEXT:\n[1] (source: …)\n…\n\nQUESTION: <q>\n\nAnswer with citations:
```

**Scoring (independent fixed judge).** Because keyword overlap saturates, RAG answers are graded by an **LLM-as-judge held fixed across all models** — `Qwen2.5-VL-72B-Instruct` on pinned vLLM v0.23.0, the same judge as our adopted 6-model baseline, so every RAG number is directly comparable. The judge sees (question, reference, candidate) and returns a strict verdict (temperature 0, JSON):
```
System: You are a strict grader for a financial-regulation QA system. Compare the
CANDIDATE answer to the REFERENCE answer for the QUESTION. Return JSON
{"correct": true|false, "score": 0-100, "reason": "..."}. correct=true only if the
candidate is factually consistent with the reference and does not add unsupported
claims. Brevity is fine.
```
To avoid confounding the judge with the model under test, answers are **collected first and judged in a separate pass** by the one fixed judge. **Accuracy = % `correct`**, with a Wilson 95% CI (n≈250).

### 2.5 Speed and cost

- **Latency (managed/frontier):** per-request end-to-end through the gateway, reported as p50/p95 from the gateway's per-request metadata.
- **Throughput (self-hosted):** peak aggregate tokens/s under a 64-concurrent load generator — *a throughput you own*, not a single-request latency. These two speed metrics are **not directly comparable**; we report each where it applies.
- **Cost — managed:** provider list price, $/M **output** tokens (`bench/pricing/managed.yaml`, as-of 2026-06-18; Anthropic first-party list, OSS-on-Bedrock from the AWS Price List API, us-west-2 on-demand).
- **Cost — self-hosted:** measured spot $/hr ÷ peak aggregate tok/s = $/M output. **This is a best case** (peak utilization, point-in-time spot); real average utilization is lower, so effective $/M is higher. The two cost bases differ *on purpose* (managed bundles the operator's margin; self-host is raw rental you operate).

### 2.6 Controls and reproducibility

Temperature 0 everywhere; one retrieval pipeline; one fixed judge; identical prompts and concurrency profiles. Data is fully synthetic or public-domain (ADR-0004), deterministic given pinned seeds (Synthea v4.0.0 / seed 1337; FATURA at a pinned revision; degradation seeded per item index) so a clean checkout regenerates byte-identical documents and gold. A completeness guard fails any run whose section completes < 80% of attempts, so a silent mass-drop cannot masquerade as a passing score.

---

## 3. Results

### 3.1 Per-model scorecard (the headline)

Each model on every axis, self-hosted **and** managed. Extraction shows the hardest applicable tier; RAG is fixed-judge accuracy (n≈250); speed is latency p50 for managed / peak throughput for self-host; cost is $/M output.

| Model | Substrate | Extraction¹ | RAG² | Speed³ | $/M-out⁴ |
|---|---|--:|--:|--:|--:|
| **Qwen3-VL-235B** | Self-host (FP8, 8×H200) | 97.9 / 83.7 | 28.8 | 3,838 tok/s | $1.30 |
| | Bedrock | 97.9 / 83.7 | 30.0 | 2.9 s | $2.66 |
| **Llama-4-Scout** ⁵ | Self-host (BF16, 8×H100) | 91.3 / 72.3 | 25.2 | 3,927 tok/s | $1.01 |
| | Bedrock | 91.3 / 71.7 | 24.8 | 0.8 s | $0.66 |
| **GLM-4.7** | Self-host (FP8, 8×H100) | 99.3 (clean) | 36.8 | 3,120 tok/s | $1.27 |
| | Bedrock | — | 32.8 | 1.3 s | $2.20 |
| **Kimi-K2.5** | Self-host (INT4, 8×H200) | 100.0 (clean) | 37.6 | 2,295 tok/s | $2.18 |
| | Bedrock | — | 32.4 | 1.4 s | $3.00 |
| **DeepSeek-V3.2** | Self-host (FP8, 8×H200) | 99.4 (clean) | 34.8 | 1,403 tok/s | $3.56 |
| | Bedrock | — | 30.8 | 1.8 s | $1.85 |
| **DeepSeek-V4-Pro** ⁷ | Self-host (FP4+FP8, 8×H200) | 98.4 (clean) | **40.0** | pending | pending |
| **GLM-5.2 / GLM-5** ⁶ | Self-host GLM-5.2 (FP8, 8×H200) | 99.3 (clean) | 33.2 | 1,357 tok/s | $3.69 |
| | Bedrock (GLM-5) | 99.4 (clean) | 30.8 | 2.4 s | $3.20 |
| **Opus 4.8** *(frontier)* | Bedrock | 99.4 / 93.7 | 32.4 | 4.7 s | $25.00 |
| | Anthropic direct | 99.7 / 94.0 | 32.8 | 2.8 s | $25.00 |
| **Sonnet 4.6** *(frontier)* | Bedrock | 99.4 / 88.7 | 24.6 | 3.5 s | $15.00 |
| | Anthropic direct | 99.5 / 89.3 | 25.2 | 3.6 s | $15.00 |

¹ Vision models: **medical-degraded / commercial-degraded** F1 (hardest scanned tiers). Text-only models: **clean-digital** F1 (their only tier — no vision path). ² RAG fixed-judge accuracy; **read the cluster, not the rank** (§4.2). ³ Managed = per-request latency p50; self-host = peak aggregate throughput at 64-concurrent — *different metrics* (§2.5). ⁴ $/M output; managed list price, self-host = spot $/hr ÷ peak tok/s (best case). ⁵ Strict same-weights pair. ⁶ Family pair, **not** same-weights (GLM-5.2 self vs GLM-5 Bedrock). ⁷ DeepSeek-V4-Pro (1.6T MoE, added 2026-06-30): self-hosted only, text-only reasoner; RAG **40.0%** is top of the lineup among named models. Throughput/$ pending the cost/loadgen pass (FP4 experts via Marlin on Hopper → the $/M will be a Hopper number).

### 3.2 Quality — extraction (vision models, by tier)

| Model | Substrate | med-deg | com-deg |
|---|---|--:|--:|
| Opus 4.8 | Bedrock | 99.4 | 93.7 |
| Opus 4.8 | Anthropic direct | 99.7 | **94.0** |
| Sonnet 4.6 | Bedrock | 99.4 | 88.7 |
| Sonnet 4.6 | Anthropic direct | 99.5 | 89.3 |
| Qwen3-VL-235B | Self-host | **97.9** | 83.7 |
| Qwen3-VL-235B | Bedrock | 97.9 | 83.7 |
| Llama-4-Scout | Self-host | 91.3 | 72.3 |
| Llama-4-Scout | Bedrock | 91.3 | 71.7 |

med-deg NPI-corrected 2026-06-30 (was Opus 96.4/96.3, Sonnet 96.1/96.0, Qwen3-VL 95.0/94.7, Scout 84.6/84.7); com-deg unchanged (no NPI field). Text-only models on their clean-digital tier: **Kimi-K2.5 100.0, DeepSeek-V3.2 99.4, GLM-4.7 99.3, GLM-5.2 99.3, DeepSeek-V4-Pro 98.4** (self-host); **GLM-5 99.4** (Bedrock). **NPI is no longer a weak field** — the prior weakness was a gold-data artifact (`provider_npi` stored a UUID, not a 10-digit NPI), corrected 2026-06-30; medical extraction now saturates 97–100% across the lineup (§4.1, §2.3).

### 3.3 Quality — RAG (all models, n≈250, fixed judge)

| Model | Self-host | Bedrock / frontier |
|---|--:|--:|
| Kimi-K2.5 | **37.6** [31.8, 43.7] | 32.4 |
| GLM-4.7 | 36.8 [31.1, 42.9] | 32.8 |
| DeepSeek-V3.2 | 34.8 [29.2, 40.9] | 30.8 |
| GLM-5.2 / GLM-5 | 33.2 [27.7, 39.3] | 30.8 |
| Qwen3-VL-235B | 28.8 [23.5, 34.7] | 30.0 |
| Opus 4.8 | — | 32.4 / 32.8 |
| Llama-4-Scout | 25.2 [20.2, 30.9] | 24.8 |
| Sonnet 4.6 | — | 24.6 / 25.2 |

The ~30–33% group (Kimi, GLM-4.7, DeepSeek, GLM-5, Opus, Qwen3-VL) is a **statistical tie** — CIs span ~±6 points and overlap heavily.

### 3.4 Speed and cost

**Managed latency p50 / p95 (s):** Scout 0.8 · GLM-4.7 1.3 · Kimi 1.4 · DeepSeek 1.8 · GLM-5 2.4 (p95 24.7, thinking tail) · Qwen3-VL 2.9 · Sonnet 3.5 · Opus-direct 2.8 vs Opus-Bedrock 4.7 (p95 ~11.6). **Self-hosted peak throughput (tok/s):** Scout 3,927 · Qwen3-VL 3,838 · GLM-4.7 3,120 · Kimi 2,295 · DeepSeek 1,403 · GLM-5.2 1,357.

**Cost.** Frontier output tokens run **8–38×** the OSS-on-Bedrock models: Opus $25/M, Sonnet $15/M vs $0.66–$3.20/M. Self-hosting the same open weights *at peak utilization* beats Bedrock for most of the lineup (GLM-4.7 $1.27 vs $2.20, Qwen3-VL $1.30 vs $2.66, Kimi $2.18 vs $3.00) but **loses for DeepSeek-V3.2** ($3.56 self vs $1.85 Bedrock) and **Llama-4-Scout** ($1.01 self vs $0.66 Bedrock, dirt-cheap managed). Spot basis: 8×H100 (`p5.48xlarge`) $14.22/hr; 8×H200 (`p5e.48xlarge`) ~$18/hr, **shortage-elevated 2026-06-19** — at the typical ~$14 the H200 self-host rows fall ~22% (Qwen3-VL→$1.01, Kimi→$1.70, DeepSeek→$2.77).

### 3.5 Calibration check (A vs B)

The test of a fair harness: each self-hosted score should land on its managed twin. It does, on both axes.

- **Extraction:** Qwen3-VL commercial-degraded **identical to the decimal** (83.7 / 83.7), and on NPI-corrected medical-degraded the pair is also **identical (97.9 vs 97.9)**. Llama-4-Scout (exact same weights) matches on both vision axes — med-deg **91.3 vs 91.3** (post-NPI-fix), com-deg 72.3 vs 71.7.
- **RAG:** every self-hosted score sits inside its managed twin's CI. Notably the self-hosted figure lands *nominally higher* on four of five (Kimi +5.2, DeepSeek +4.0, GLM-4.7 +4.0, Qwen3-VL −1.2) — within noise, but consistent enough to flag a possible real serving/precision edge for the sovereign stack.

**Substrate-invariance holds.** Same weights → same quality regardless of who serves them.

---

## 4. Discussion

### 4.1 The frontier premium is a *commercial*-degraded-extraction phenomenon

On commercial-degraded scans, Opus (94%) leads the best open model, Qwen3-VL-235B (83.7%), by ~10 points; Sonnet sits between (88.7%). On medical-degraded the gap **closes entirely** once the `provider_npi` gold bug is corrected (§2.3): the whole lineup saturates (Opus 99.4, Qwen3-VL 97.9, Ornith 99.7), with only Llama-4-Scout trailing at 91.3 — so medical extraction no longer separates the field. (Before the fix the medical gap already looked small, 96.4 vs 95.0; the residual was an artifact — a 36-char UUID in the NPI field is hard to OCR on degraded scans, which cost even the frontier points.) Llama-4-Scout is the weakest vision extractor on commercial (72%) — *natively multimodal ≠ good at document vision*. So the case for paying 8–38× per token is specifically **hard, degraded *commercial*-layout extraction accuracy**, and nowhere else.

### 4.2 The premium does not transfer to RAG

Grounded QA clusters at ~30–33% across Opus, GLM-4.7, Kimi, DeepSeek, GLM-5, and Qwen3-VL with overlapping CIs — the frontier does **not** lead. Two cautions on the metric: (a) it scores answer-match against terse reference answers, so it rewards concise, extractive answers over synthesis; (b) **Sonnet's low 24.6% is a style artifact, not weaker RAG** — Sonnet refuses *less* (6% vs 7%) and cites *more* (99% vs 94%) than Opus, but writes ~30% longer enumerated answers that the strict gold-match judge penalizes. A containment-style judge would neutralize this; changing the judge, however, breaks comparability with the version-locked baseline, so it is a v2 decision. The honest reading: **on RAG, choose by cost and latency, not by RAG rank.**

### 4.3 Self-hosting economics: utilization + sovereignty, not a blanket win

Per output token at peak utilization, self-hosting beats Bedrock for most of the lineup — but not the cheap-on-Bedrock model (Scout) or the slow reasoner (DeepSeek). The lever is **utilization**: the self-host figures assume peak 64-concurrent throughput on shortage-elevated spot; average utilization is lower and shortage pricing inflates the H200 rows. The durable self-host arguments are therefore (1) cost *at high, sustained utilization*, and (2) sovereignty/data-control — not a universal per-token saving. **Reasoning models carry a throughput tax:** DeepSeek-V3.2 (1,403 tok/s) and GLM-5.2 (1,357 tok/s) generate long chains per request, which is why they are the priciest to self-host.

### 4.4 Threats to validity

1. **FATURA `buyer_name` gold bug (fixed).** ~45–50% of `buyer_name` gold values were the literal label "Bill to"; corrected in `build.py` and all managed models re-scored on the corrected 5-field gold (the com-deg column). The fix *raised* commercial F1 across the board (e.g. Opus 92.9→93.7, Scout 66.2→71.7). One straggler: self-hosted Scout's commercial uses the corrected gold as of 2026-06-20 (72.3%).
2. **RAG judge style bias** (§4.2) — the version-locked judge penalizes verbose, multi-part answers; read the RAG cluster as tied.
3. **Latency ≠ throughput** — managed latency is best-effort per-request (Bedrock throttles as added latency, not errors; the guaranteed lever is Provisioned Throughput); self-host throughput is owned capacity. Reported separately, never merged.
4. **GLM-5/5.2 is a family pair, not same-weights** — do not read that row as a calibration check.
5. **Self-host $/M is best-case** — peak utilization, point-in-time shortage-elevated spot.

---

## 5. Conclusions

### 5.1 Best all-around

For a **mixed enterprise document workload** (scanned intake *and* grounded QA), the best all-around open-weight model is **Qwen3-VL-235B**. It is the only open model strong on *both* axes — best open document-vision extraction (matching its Bedrock twin to the decimal at 83.7% on degraded scans), a competitive ~29–30% on RAG — at low cost ($1.30/M self-hosted, $2.66 Bedrock) and the highest open-model throughput tested (3,838 tok/s). If the workload is **text-only** (no scanned images), **GLM-4.7** is the better all-rounder: top-cluster RAG (36.8% self-hosted), strong clean-digital extraction (99.3%, NPI-corrected gold), the cheapest self-host ($1.27/M), and the fastest managed latency (1.3 s).

**Pay for the frontier (Opus 4.8) only when degraded-document extraction accuracy is the priority** — that is the one axis where its ~10-point lead and 8–38× cost are justified. For grounded RAG or clean-digital extraction, the premium buys little.

### 5.2 Situational guide

| If your priority is… | Pick | Why (from the data) |
|---|---|---|
| Hardest scanned-document extraction accuracy | **Opus 4.8** | 94% com-deg, ~10 pts over the best open model; the frontier premium is real *here* |
| Best open vision+text all-rounder | **Qwen3-VL-235B** | matches Bedrock to the decimal on extraction, ~30% RAG, $1.30 self, 3.8k tok/s |
| Text-only docs, best RAG + economics | **GLM-4.7** | 36.8% RAG self, $1.27/M self, 1.3 s managed, 3.1k tok/s |
| Lowest cost / latency, clean inputs | **Llama-4-Scout** | $0.66/M Bedrock, 0.8 s, 3.9k tok/s — but weakest extraction (72% com-deg) |
| Maximum data sovereignty | **any self-host (Qwen3-VL / GLM-4.7 best value)** | calibration proves self-host reproduces managed quality |
| Grounded RAG specifically | **treat as a tie; choose on cost/latency** | the ~30–33% cluster's CIs overlap — RAG rank is not decisive |
| Cheapest *managed* text extraction | **DeepSeek-V3.2 (Bedrock, $1.85)** | but self-hosting it loses (reasoning throughput tax) |

### 5.3 Bottom line

The sovereign stack is **not a quality compromise**: on identical inputs it reproduces the managed provider's output on every axis. The real decision is an economic and operational one — utilization, latency profile, and data-control posture — and, for the single case of degraded-layout extraction, whether the frontier's accuracy edge is worth its premium.

---

## Appendix — provenance & reproducibility

- **Managed result JSONs:** `s3://kelsus-refarch-models-scale-<acct>/results/quality/managed-*.json`; per-model RAG verdicts: `bench/quality/<model>.judged.json`.
- **Runner:** `bench/managed-sweep.sh` (+ `bench/job-quality-managed.yaml`); self-host throughput via `bench/loadgen.py`. **Scorer:** `bench/quality/score.py` (+ `judge.py`, `stats.py`). **Judge:** `infra/helm/vllm-scale.yaml` (Qwen2.5-VL-72B, vLLM v0.23.0).
- **Data generators:** `data/synthea/`, `data/fatura/build.py`, `data/corpus/build.py`; pins in `data/README.md` (Synthea v4.0.0 / seed 1337; FATURA pinned revision; degradation seeded per item index).
- **Pricing:** `bench/pricing/managed.yaml` (as-of 2026-06-18).
