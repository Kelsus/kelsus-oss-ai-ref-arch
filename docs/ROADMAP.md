# Roadmap

Phased build of the sovereign reference architecture. Each phase is gated by a
concrete, checkable outcome. Maps to the 90-day capabilities sprint (W4–W12) and
beyond.

## Sprint 0 — Foundation ✅
Repo, ADRs, runbook, validated Terraform for `dev` + `scale` (shared stack
module), the synthetic-data generators, the Makefile, and the serving/app/bench
scaffolds. AWS readiness confirmed (`kelsus-dev`, 384 GPU vCPU quota).

## Sprint 1 — Synthetic data pipeline
- Synthea → CMS-1500 / UB-04 / EOB / medical-invoice PDFs **+ gold labels**.
- FATURA labeled commercial invoices ingested + mapped to our extraction schema.
- CMS DE-SynPUF Sample 1 staged for the reconcile/chase workload.
- SEC EDGAR (EX-10 lending agreements) + NIST corpus built, parsed, chunked.
- **Gate:** every document has a machine-checkable ground-truth label.

## Sprint 2 — Apps end-to-end (dev scale)
- vLLM (small model) + embeddings/reranker + FastAPI gateway (PII redaction, grounding guards) on the dev cluster.
- App 1 (claims intake): ingest → extract → classify → route → reconcile → chase.
- App 2 (sovereign RAG): retrieve + rerank → answer with citations → grounding guard.
- **Gate:** `make smoke` serves both apps end-to-end, never leaving the VPC.

## Sprint 3 — Benchmark harness emits metrics
- `bench/` workloads: RAG quality, function calling, long context, cost/latency.
- Outputs raw CSV + `summary.json` per run; two runs per model for variance.
- **Gate:** a full run produces extraction F1, RAG quality, TTFT/p95, throughput, $/M-token.

## Sprint 4 — Scale benchmark (staged)

Run in three steps to de-risk GPU spend. Dev-tier eval sets are demo-sized
(40 invoices, 39 docs, 3 RAG questions) — far too small to rank models (±15–28 pt
CIs). A credible benchmark needs ~300–500 labeled items/workload (±~5 pt), per the
Index methodology. So data first, then a cheap validation, then the sweep.

**Step 1 — Scale the eval sets (GPU-free, ~free)** [tasks #1–3]
- ~400 invoices + gold from Synthea (extraction). [#1]
- RAG corpus 39 → ~1k+ public Fed-Register/SEC docs. [#2]
- ~300–500 passage-grounded RAG QA pairs + an **LLM-as-judge** (the keyword proxy saturated at 100%). [#3]
- Report every quality score with its 95% confidence interval.

**Step 2 — Validation run (~$25–40)** [task #4]
- Bring up `g6e.12xlarge` (4× L40S, **TP=4**, no-egress, private API); serve one model that fits (Mistral Large); run the full harness end-to-end over the scaled eval sets. Proves multi-GPU serving + the pipeline before the sweep.

**Step 3 — Full sweep across two hardware tiers** [task #5]
- **g6e.12xlarge (4× L40S, 192 GB)** — mid-size models: Mistral Large (123B), Llama 4 Scout (~109B), Qwen 3.5 235B (quantized).
- **p5 / H100 (8× H100, 640 GB)** — the frontier MoE that *cannot* fit L40S: **DeepSeek V4 (~671B), Kimi K2 (~1T)**. **DECIDED (Jon):** we go to H100 — it's within budget, and a core goal is to **demonstrate that frontier-scale open models are runnable on hardware anyone can rent by the hour** ("sovereignty all the way up," not just the safe mid-size models). Most people don't realize self-hosting a 671B/1T model is accessible — showing it is the point.
- **DECIDED (Jon): H100 runs go on spot instances** (~50–70% off on-demand; the sweep is an interruption-tolerant batch). On-demand only as fallback if spot capacity is unavailable.
- ~$100–150 (g6e tier) + ~$100–200 (H100 flagships on spot); AWS credits are the other lever.
- **Gate:** per-model cost/latency + quality, each with a CI, reproducible within tolerance.

**Step 3a.5 — same-silicon perf table (DECIDED: Jon).** Quality scores are
GPU-independent, but **cost/latency comparisons are only valid on identical
hardware**. The Tier B (H100) session therefore includes perf-only re-runs of
every Tier A model on the pinned p5 box (~30 min each, `bench/run.sh` only —
no quality re-run). Published table: one hardware column per GPU class; the
A100-vs-H100 rows for the same model double as a "which GPU should I rent?"
answer.

**Step 3b — Bedrock-in-VPC comparison baseline** [task #8] **(DECIDED: Jon)**
- Add a **managed-alternative column** to the benchmark: the same workloads measured against **Amazon Bedrock (via PrivateLink, data stays in-VPC)** — latency, $/M tokens at list price, and where the self-host break-even sits.
- This makes the strategy's strongest differentiator *demonstrable*: "we tell the truth about when self-hosting is wrong." No competing benchmark includes the managed alternative.
- Mostly GPU-free (Bedrock latency from a CPU pod; cost from the published price sheet); feeds §8 break-even directly.

**Step 4 — Backfill + reconcile** [task #6] → flows into Sprint 5.
- Includes the Bedrock comparison column in §7/§8 and the spot-vs-on-demand cost note.

### Content angles (feed the Phase 2 blog cadence — capture now, write at publish)
- **"The $25 benchmark"** *(Jon)* — cost transparency about the benchmarking itself: a full validation run on rentable GPUs costs less than lunch. Reinforces the "normies can do this" thesis that the H100 story scales up.
- **The dev-tier difficulty curve** — "what a 7B vision model can and can't do on document workloads" (99% rigged → 94.6% medical / 70.7% commercial on degraded scans). Already written in `docs/benchmarks/`; engineer-forwardable.
- **The sharp-edges series** — SE-1…6 from `operational-learnings.md` ("four things that broke putting vLLM on EKS").

> Hardware note: TP=4 on g6e.12xlarge; TP=8 on p5.48xlarge. The biggest MoE models
> (DeepSeek V4, Kimi K2) require H100-class memory — they will not run on L40S.

## Sprint 5 — Publish
- Measured numbers backfill [`architecture.md`](architecture.md); validate or correct the website's pre-published figures.
- Sanitization pass; public Apache-2.0 GitHub release.
- **Gate:** the writeup has no remaining `[TO MEASURE]` markers.

---

## Phase 6 — Living Benchmark Site  *(big, fancy — queued, not now)*
> Requested by Jon. A polished, customer-ready public microsite for the reference
> architecture **and** the benchmark results, **linked from kelsus.com**, that
> **updates itself when benchmarks run**. The goal: an end-to-end system where we
> test a new model and the results land in a pretty, ready-to-show place — turning
> "we deploy what we benchmark" into a live, self-evidencing artifact.

**What it is**
- A designed marketing-grade site: the architecture story + diagram + SLOs (makes the existing `kelsus-website/reference-architecture.html` real), plus a **/benchmarks** section with per-workload charts, cost/latency curves, and per-model notes.
- Per-workload presentation only — **no single composite score** (consistent with the Benchmark Index methodology). Honest per-field F1, named losing models, links to raw data.

**The "self-updating" pipeline (the actual feature)**
```
make bench MODEL=<candidate>
  └─► bench/reports/runs/<ts>/{*.csv, summary.json}        (raw, reproducible)
        └─► publish step  →  results bucket (S3, versioned, public-read)  +  /benchmarks data (JSON)
              └─► site build (Astro/Next) reads results JSON
                    └─► CI/CD (GitHub Actions or AWS Amplify) redeploys behind CloudFront
                          └─► new numbers appear on the public site, automatically
```
- New model → run the harness → results are visible publicly with no manual slide-making.
- A "what's new this quarter" diff view to ride the quarterly Index cadence.

**Guardrails / design constraints**
- The public site shows **synthetic-data** benchmark results only — no customer data, ever. It is a *marketing/credibility* artifact, architecturally separate from the in-VPC sovereign customer deployments.
- Reproducibility is the point: every published number links to the raw CSV + the exact `bench/configs/<model>.yaml` that produced it.
- Built with the `frontend-design` skill for genuine design quality (the bar: "a staff engineer forwards it to their team").
- Publication channel aligns with the Index's open decision (PDF + site + GitHub release).

**Rough shape of the work (when we pick it up)**
1. Define the published results schema (`summary.json`) the site consumes — do this *early* in Sprint 3 so the harness emits site-ready output from the start.
2. Results store + publish step (S3 versioned bucket + transform).
3. The designed site (architecture + /benchmarks) — frontend-design skill.
4. CI/CD trigger: new results in the bucket → rebuild + deploy → CloudFront.
5. Link from kelsus.com; wire the quarterly-diff view.

**Sequencing:** lands after Sprint 5 (needs real numbers + a stable harness output). The one thing to do *now* is keep the harness's `summary.json` schema clean and forward-looking so Phase 6 is a publish layer on top, not a rework.
