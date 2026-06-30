# Same-weights comparison — sovereign self-hosted vs. Bedrock vs. the frontier

**Status: COMPLETE 2026-06-20 — five self-hosted models + all managed (Bedrock + Anthropic): extraction, RAG (fixed-judged), commercial (corrected 5-field gold), and self-hosted throughput + $/M-out all measured. Same-weights calibration holds on every axis — Scout, the exact-weights pair, matches Bedrock on all three. UPDATED 2026-06-22: added the GLM-5 family — GLM-5.2 self-hosted (97.0% extraction / 33.2% RAG) + GLM-5 on Bedrock (96.1% / 30.8%), the newest open flagship and top-of-lineup on extraction (footnote ⁸: a family addition, not a strict same-weights pair). UPDATED 2026-06-27: added Ornith-1.0-397B (deepreinforce-ai), self-hosted only with no Bedrock twin — a 397B vision+reasoning MoE that ties the frontier on medical-degraded extraction (96.3%), lands top-of-cluster on RAG (35.2%), and self-hosts at $1.99/M-out (footnote ⁹). UPDATED 2026-06-29: added Nemotron-3-Ultra-550B-A55B (NVIDIA), self-hosted only — a 560B hybrid Mamba-MoE served NVFP4 on 8×H100 via the Marlin FP4 fallback; clean-digital extraction 96.3%, RAG 36.4% (top-of-cluster), $1.96/M-out (footnote ¹⁰).**

## What this is

One workload, one harness, three substrates — so the only thing that varies is *who runs the
model and on what*. Built to answer the question buyers actually ask: how does self-hosting an
open-weight model compare to "just call Bedrock" or "just use the frontier"?

- **Layer A — sovereign self-hosted** (our vLLM on rented GPUs, in-VPC): the current-gen open
  weights, re-run on our stack. All five served single-box on one 8×H200 box (pinned vLLM v0.23.0).
- **Layer B — same model on Bedrock**: the *same family/checkpoint* Bedrock serves, so A vs B
  isolates the substrate (our serving vs theirs) on price/quality/duration.
- **Layer C — frontier**: Claude Opus 4.8 + Sonnet 4.6, via Bedrock **and** direct Anthropic —
  "what you give up vs the frontier, inside AWS's walls or out."

Everything routes through the same gateway (identical retrieval, prompts, vision routing,
per-tier scoring). RAG is scored by one fixed judge (`Qwen2.5-VL-72B-Instruct`, vLLM v0.23.0) —
the same judge as the adopted 6-model baseline, so RAG numbers are directly comparable across all
of it. Synthetic data only (ADR-0004).

## Managed results (Layers B + C) — 2026-06-19

Extraction F1 is per-tier vs gold (deterministic); RAG is the fixed-judge accuracy (n=250).
`med-deg` / `com-deg` = scanned-degraded (the hard headline tiers). Latency is per-request,
end-to-end through the gateway.

| Model | Substrate | med-deg F1 | com-deg F1¹ | RAG² | latency p50 | $/M out³ |
|---|---|--:|--:|--:|--:|--:|
| **Opus 4.8** | Bedrock | 96.4% | 93.7% | 32.4% | 4.7 s | $25.00 |
| **Opus 4.8** | Anthropic direct | 96.3% | 94.0% | 32.8% | 2.8 s | $25.00 |
| **Sonnet 4.6** | Anthropic direct | 96.0% | 89.3% | 25.2% | 3.6 s | $15.00 |
| **Sonnet 4.6** | Bedrock | 96.1% | 88.7% | 24.6% | 3.5 s | $15.00 |
| Qwen3-VL-235B | Bedrock | 94.7% | 83.7% | 30.0% | 2.9 s | $2.66 |
| Llama-4-Scout | Bedrock | 84.7% | 71.7% | 24.8% | 0.8 s | $0.66 |
| DeepSeek-V3.2 (text) | Bedrock | — | — | 30.8% | 1.8 s | $1.85 |
| GLM-4.7 (text) | Bedrock | — | — | 32.8% | 1.3 s | $2.20 |
| Kimi-K2.5 (text) | Bedrock | — | — | 32.4% | 1.4 s | $3.00 |
| GLM-5 (text)⁸ | Bedrock | — | — | 30.8% | 2.4 s | $3.20 |

¹ **com-deg F1 is the corrected 5-field score** (all `*-commfix` re-scores landed 2026-06-19). The
FATURA gold's `buyer_name` had been corrupted (the "Bill to" label captured as the value for ~45–50%
of invoices); fixed in `data/fatura/build.py`. Fixing it *raised* com-deg across the board (e.g. Opus
92.9→93.7, Scout 66.2→71.7) because `buyer_name` now scores ~95–100% instead of as a broken field.
See Caveats.
² RAG by the fixed judge; **read the cluster, not the rank** — see Caveats.
³ Managed list price, $/M **output** (`bench/pricing/managed.yaml`, as-of 2026-06-18). Anthropic from
the first-party list (Bedrock-Claude assumed same — verify); OSS-on-Bedrock from the AWS Price List
API (us-west-2, standard on-demand). The self-hosted $/M-out (Layer A) prices on a different basis —
see Pricing basis.

### What the managed numbers already show

- **Harness calibration holds:** Opus-Bedrock ≈ Opus-direct on quality (96.4/96.3 med-deg,
  93.7/94.0 com-deg, 32.4/32.8 RAG) — same weights, two substrates, same score. The real
  difference is **latency: direct Anthropic is faster** (2.8 s vs 4.7 s p50; Bedrock's tail
  reaches ~11.6 s p95). Sonnet is the exception — Bedrock ≈ direct on latency too (3.5 s vs 3.6 s).
- **The frontier premium is an *extraction* phenomenon, on hard layouts.** On commercial-degraded,
  Opus (~94%) leads the best open model, Qwen3-VL-235B (83.7%), by ~10 points; on
  medical-degraded they're close (96.4 vs 94.7). Llama-4-Scout remains the weakest vision
  extractor (71.7% com-deg) — natively-multimodal ≠ document-vision-good.
- **The premium does NOT transfer to RAG.** Grounded QA clusters ~30–33% (Opus, GLM-4.7, Kimi,
  DeepSeek, Qwen3-VL — overlapping CIs), with Sonnet and Scout trailing. The frontier does not lead
  here — see the RAG caveat.
- **Cost: steep frontier premium, and self-hosting wins per-token for most — but not all.** Per
  output token, Opus ($25/M) and Sonnet ($15/M) run ~8–38× the OSS-on-Bedrock models ($0.66–$3.00/M
  out). Self-hosting the same open weights *at peak utilization* now beats Bedrock for most of the
  lineup — GLM-4.7 $1.27 vs $2.20, Qwen3-VL $1.30 vs $2.66, Kimi $2.18 vs $3.00 — but **loses for
  DeepSeek-V3.2** ($3.56 self vs $1.85 Bedrock; its slow reasoning + DSA throughput, 1,403 tok/s,
  makes self-hosting pricier) and **Llama-4-Scout** ($1.01 vs $0.66; dirt-cheap on Bedrock). And the
  self-hosted figures are best-case (peak 64-concurrent, on a shortage-elevated H200 spot). So the
  self-hosting case is **utilization + sovereignty, not a blanket per-token win** — see Layer A ⁷.

## Caveats (read before quoting any number)

1. **FATURA `buyer_name` gold bug (fixed).** ~45–50% of `buyer_name` gold values were the literal
   label "Bill to", which had flattened commercial F1 (the pre-fix "91.0% clean ceiling" was
   entirely this). Fixed in `build.py`, corrected gold pushed, and **all managed models re-scored on
   the corrected 5-field gold** (the `com-deg` column above). Net effect: F1 *rose* once
   `buyer_name` scored as a real field. One straggler: self-hosted Scout's commercial is still on
   pre-corrected gold — see Layer-A footnote ⁴.
2. **RAG: read the cluster, not the rank.** CIs overlap heavily (~±6 pts) — the ~30–33% group is
   statistically tied. The metric scores grounded answer-match against terse gold, so it rewards
   concise, extractive answers over synthesis.
3. **Sonnet's low RAG (25.2%) is a style artifact, not weaker RAG.** Sonnet refuses *less* (6%
   vs 7%) and cites *more* (99% vs 94%) than Opus, but writes ~30% longer, multi-part enumerated
   answers ("the CFPB took two notable actions: 1…2…") that the strict gold-match judge penalizes.
   Not a harness bug — the judge is the version-locked baseline judge (can't change without
   breaking comparability). A containment-style judge would neutralize this; that's a v2 decision.
4. **Duration ≠ throughput.** Managed latency is per-request and best-effort — under load Bedrock
   throttles as *added latency*, not errors; the guaranteed-throughput lever is Provisioned
   Throughput (anyone can buy it). Self-hosting's number is a throughput you own. Reported separately.

## Layer A — sovereign self-hosted (COMPLETE)

The apples-to-apples partner for each Layer-B row, re-run on our stack (current-gen weights, same
harness). Ornith-1.0-397B and Nemotron-3-Ultra-550B are the exceptions — self-hosted-only open models with no Bedrock twin, reported as standalone data points (footnotes ⁹, ¹⁰). Fills in after the GPU windows:

| Model | Self-host config | med-deg F1 | com-deg F1 | RAG | $/M out |
|---|---|--:|--:|--:|--:|
| Qwen3-VL-235B | FP8, 8×H200 TP=8 | **95.0%** | **83.7%** | 28.8% [23.5, 34.7] | $1.30 (H200)⁷ |
| Ornith-1.0-397B⁹ | BF16, 8×H200 TP=8 | **96.3%** | 81.0% | 35.2% [29.5, 41.3] | $1.99 (H200)⁷ |
| Kimi-K2.5 (text) | INT4, 8×H200 TP=8⁶ | — | — | **37.6%** [31.8, 43.7] | $2.18 (H200)⁷ |
| GLM-4.7 (text) | FP8, 8×H100 TP=8 | — | — | 36.8% [31.1, 42.9] | $1.27 (H100)⁷ |
| GLM-5.2 (text)⁸ | FP8, 8×H200 TP=8 | — | — | 33.2% [27.7, 39.3] | $3.69 (H200)⁷ |
| DeepSeek-V3.2 (text) | FP8, 8×H200 TP=8⁶ | — | — | **34.8%** [29.2, 40.9] | $3.56 (H200)⁷ |
| Nemotron-3-Ultra-550B (text)¹⁰ | NVFP4, 8×H100 TP=8 | — | — | 36.4% [30.7, 42.5] | $1.96 (H100)⁷ |
| Llama-4-Scout | BF16, 8×H100 TP=8 (exact match) | 84.6% | 72.3%⁴ | 25.2% [20.2, 30.9] | $1.01 (H100)⁵ |

⁴ Scout's self-hosted com-deg, re-scored on the corrected 5-field gold (2026-06-20): **72.3%**
[67.0, 77.1] — matching its Bedrock twin (71.7%) to within noise. Calibration now holds on all three
axes for the exact-same-weights pair: med-deg 84.6 vs 84.7, com-deg 72.3 vs 71.7, RAG 25.2 vs 24.8.
⁵ Scout $/M-out from the scale-sweep at peak utilization (8×H100 `p5.48xlarge` spot). Text-model
clean-digital extraction F1 (their headline tier; vision/degraded not run): **Kimi-K2.5 97.2%**,
**GLM-4.7 95.8%**, **DeepSeek-V3.2 95.2%**, **Nemotron-3-Ultra 96.3%**.
⁶ Both serve **single-box on one 8×H200 box** under pinned stable vLLM v0.23.0: Kimi-K2.5 is native
INT4 (~595 GB), DeepSeek-V3.2 official FP8 (~685 GB) — both fit the 1,128 GB. The earlier
"Kimi full-precision multi-node" / "DeepSeek nightly-vLLM + AWQ" plans were unnecessary (premised on
640 GB H100 sizing and a stale Sept-2025 recipe); v0.23.0 carries `DeepseekV32` + DSA natively.
⁷ Self-hosted $/M-out = peak aggregate tok/s (64-concurrent `loadgen`) ÷ measured spot $/hr. **Peak
tok/s:** Qwen3-VL 3,838 · GLM-4.7 3,120 · Ornith 2,710 · Kimi-K2.5 2,295 · Nemotron 2,006 · DeepSeek-V3.2 1,403 · GLM-5.2 1,357 (Scout 3,927, from the
scale-sweep). **Spot $/hr:** 8×H100 (`p5.48xlarge`) $14.22; 8×H200 (`p5e.48xlarge`) ~$18 —
**shortage-elevated 2026-06-19** (typical ~$14; re-priced at $14 the H200 rows drop ~22%: Qwen3-VL
→$1.01, Kimi→$1.70, DeepSeek→$2.77). Point-in-time spot at **peak** utilization (best case); real-world
average utilization is lower, so effective $/M is higher. Reasoning models (DeepSeek, Kimi) throughput
lower — long reasoning chains per request — which is why DeepSeek's self-hosted $/M is its weak spot.
⁸ **GLM-5 family (newest open flagship, added 2026-06-22).** Clean-digital extraction: GLM-5.2
(self-hosted) **97.0%**, GLM-5 (Bedrock) 96.1% — both top-of-lineup (varied per-field; NPI the lone
weak field, as for every model). **Caveat: this is NOT a same-weights pair** — Bedrock carries GLM-**5**
(745B), we self-host GLM-**5.2** (753B), a half-version newer; treat the two rows as the GLM-5 *family*,
not a calibration check like the others. Op-note: GLM-5.2 first ran at 56.1% extraction — a 1,024-token
ceiling truncating the JSON behind its reasoning, *not* a quality result; fixed by raising
`LLM_MAX_TOKENS` to 16,384 (thinking left on, consistent with the lineup). GLM-5's Bedrock latency
p95 is a long 24.7 s (thinking tail). GLM-5.2 self-hosted throughput is **1,357 tok/s → $3.69/M** (H200,
~$18 spot) — the priciest self-host in the lineup, the reasoning-model tax (it's the slowest, just past
DeepSeek-V3.2).

⁹ **Ornith-1.0-397B (deepreinforce-ai, added 2026-06-27).** A 397B `qwen3_5_moe` MoE (512 experts,
10 active), multimodal and a reasoning model (emits `<think>`), MIT-licensed, served BF16 (~794 GB)
single-box on one 8×H200 box, TP=8, pinned vLLM v0.23.0 — its registry carries
`Qwen3_5MoeForConditionalGeneration` natively, so no nightly (unlike GLM-5.2). **Self-hosted only:
not on Bedrock, so no same-weights twin** — a standalone open-model data point, not a calibration
pair. Full vision tiers ran: medical clean/scanned/degraded **97.1/97.1/96.3%**, commercial
clean/degraded **98.3/81.0%**. On medical-degraded it ties the frontier (96.3% vs Opus 96.4%) and
leads the open vision models (Qwen3-VL 95.0%, Scout 84.6%); on commercial-degraded it sits between
them (81.0%, vs Qwen3-VL 83.7% / Scout 72.3%), so the ~13-pt frontier commercial-degraded premium
holds. RAG **35.2%** [29.5, 41.3] lands top-of-cluster (Kimi 37.6, GLM-4.7 36.8, DeepSeek 34.8).
Throughput **2,710 tok/s → $1.99/M-out** at $19.42 spot (`p5en.48xlarge`, us-west-2d, 2026-06-27):
a reasoning model, but more throughput-efficient than DeepSeek-V3.2 (1,403 tok/s) and GLM-5.2
(1,357), so cheaper per token despite the reasoning. `LLM_MAX_TOKENS=16,384`, thinking left on
(consistent with the lineup).

¹⁰ **Nemotron-3-Ultra-550B-A55B (NVIDIA, added 2026-06-29).** A 560B hybrid Mamba-2 + Transformer +
MoE (`nemotron_h` / `NemotronHForCausalLM`: 512 experts / 22 per token, ~55B active), text-only and a
reasoning model (reasons by default; `--reasoning-parser deepseek_r1` strips the `<think>` block so the
extraction JSON is clean). **Self-hosted only** — not on Bedrock, a standalone data point with no
same-weights twin. Served **NVFP4 (~310 GB) single-box on one 8×H100 box, TP=8**, via vLLM's **Marlin
FP4 software fallback**: NVFP4 is hardware-accelerated only on Blackwell, but Hopper loads it for the
memory win (no FP4 speedup, ~FP8 throughput), which sidesteps both the H200 drought and the multi-node
BF16 serve (~1.1 TB) the full-precision build would need. vLLM v0.23.0 carries `NemotronHForCausalLM`
+ the Mamba kernels — no nightly. Clean-digital extraction **96.3%** [95.0, 97.2]; RAG **36.4%**
[30.7, 42.5] lands top-of-cluster (just under Kimi 37.6 / GLM-4.7 36.8). Throughput **2,006 tok/s →
$1.96/M-out** at $14.18 spot (`p5.48xlarge`, us-west-2a): the $/M is a Hopper-NVFP4 number — a
Blackwell box would be faster and cheaper.

The sanity check that proves the comparison is fair: each Layer-A score should land close to its
Layer-B partner (same weights). A gap means a serving/precision difference worth explaining.

**Calibration PASSES across extraction *and* RAG, on all five self-hosted models.** Same harness, same
fixed judge (Qwen2.5-VL-72B, v0.23.0), self-hosted vs the Bedrock twin:
- **Extraction:** Qwen3-VL commercial **identical to the decimal** (scanned-clean 99.7% / degraded
  83.7% on both), medical-degraded within noise (self 95.0% vs Bedrock 94.7%). Scout (exact same
  weights) matches on **both** vision axes — med-deg 84.6 vs 84.7, com-deg 72.3 vs 71.7 (corrected
  gold). Text models' clean-digital extraction is strong across the board: Kimi 97.2%, GLM 95.8%, DeepSeek 95.2%.
- **RAG (fixed-judge, n≈250 each):** every self-hosted score sits inside its Bedrock twin's CI —
  Kimi 37.6 vs 32.4, GLM 36.8 vs 32.8, DeepSeek 34.8 vs 30.8, Qwen3-VL 28.8 vs 30.0, Scout 25.2 vs 24.8.
  Notably the self-hosted number lands **nominally higher on four of five** (Kimi +5.2, DeepSeek +4.0,
  GLM +4.0, Qwen3-VL −1.2) — within noise, but consistent enough to flag: possibly a real serving /
  precision edge for the sovereign stack, worth a sentence when published.

Same weights → same quality regardless of who serves them, on both axes. This is the "tight ship"
result: the sovereign stack reproduces the managed provider's output on identical inputs.

## Pricing basis (state this when publishing)

- **Managed**: list price per token (`bench/pricing/managed.yaml`) — all-in, includes the
  provider's margin and the fact that someone else runs the cluster. Opus 4.8 $5/$25, Sonnet 4.6
  $3/$15 (in/out per M); OSS-on-Bedrock to verify.
- **Self-hosted**: measured spot $/hr ÷ throughput — raw GPU rental, and you operate it.
- These price on **different bases on purpose**; the per-tier quality + per-token cost trade is the
  product of the benchmark, not a single "X is cheaper" headline.

## Provenance

Managed result JSONs: `s3://kelsus-refarch-models-scale-<acct>/results/quality/managed-*.json`;
per-model RAG verdicts: `bench/quality/<model>.judged.json`. Runner: `bench/managed-sweep.sh`
(+ `bench/job-quality-managed.yaml`). Judge: `infra/helm/vllm-scale.yaml` (Qwen2.5-VL-72B, v0.23.0).
