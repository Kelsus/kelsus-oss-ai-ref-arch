# DeepSeek-V4-Pro benchmark runbook

Adds `deepseek-ai/DeepSeek-V4-Pro` to the same-weights benchmark. Work lands on the
`bench/deepseek-v4-pro` branch and folds into `public` when the numbers are in. This is
the DeepSeek build the OSS publish has been gated on.

## What DeepSeek-V4-Pro is

- **1.6T MoE / 49B active** (`DeepseekV4ForCausalLM`, 61 layers, 384 routed experts / 6
  active + 1 shared), MIT, open-weight, **not gated**.
- **Hybrid CSA + HCA sparse attention** — the direct descendant of V3.2's DSA. A learned
  token-compressor (stride 4) condenses neighborhoods into single entries; a lightning
  indexer (now **FP4/MXFP4**, down from FP8 in V3.2) picks ~128 compressed entries per
  query. This is what makes 1M context cheap (the card: 27% of V3.2's single-token FLOPs,
  10% of its KV cache at 1M).
- **Text-only, reasoning** (V4-Pro-Max = the max reasoning-effort mode) → clean-digital
  extraction + RAG only, like the other text models (GLM-5.2, DeepSeek-V3.2, Kimi,
  Nemotron). No vision tiers, no FATURA commercial set.
- **Native weights = FP4 experts + FP8 attn/router** (block 128×128), **~865 GB / 64
  shards**. The `nvidia/DeepSeek-V4-Pro-NVFP4` build is *larger* (~913 GB — it quantizes
  attention to FP4 and carries scale tensors), so it is no memory win; serve the native repo.
- **1M context** (YaRN ×16 over a 64k base). We serve `--max-model-len 32768` to match the
  lineup.

## Serving

- `infra/helm/vllm-deepseek-v4-pro.yaml`: single **8×H200** box (`gpu-h200` nodepool,
  p5e/p5en, 1,128 GB), TP=8, V4 flags (`--tokenizer-mode deepseek_v4`,
  `--reasoning-parser deepseek_v4`, `--kv-cache-dtype fp8`).
- **Topology is forced.** 865 GB does **not** fit 8×H100's 640 GB, so the Nemotron
  H100-NVFP4 escape does **not** apply to Pro — it must land on H200. But it is **single-box**
  (no LWS / multi-node, unlike GLM-5.2 BF16 and Kimi), so capacity is one node, not a
  same-AZ pair, and the `lws-deadman` does not apply. Cost guards = nightly gpu-off
  CronJob + `make gpu-off`.
- **H200 is in drought.** Expect to wait on the capacity poller rather than a first-apply
  land. Reuse the existing `glm-capacity-poller` (retarget it at this Deployment) so the
  box auto-serves when spot frees up.
- **vLLM version risk (the GLM-5.2 lesson).** The official recipe
  (`recipes.vllm.ai/deepseek-ai/DeepSeek-V4-Flash`) lists vLLM **0.20.0+**; our pinned
  stable is **v0.23.0**, so `DeepseekV4ForCausalLM` should be in the registry. But the
  recipe only documents **Flash** (284B) — **Pro (1.6T) is first-footed here.** Verify the
  arch and the FP4/MXFP4 indexer kernels load at source in the smoke test; if v0.23.0
  errors, pin a vLLM nightly (the GLM-5.2 IndexShare precedent — do not trust the card).

## Run sequence

1. **Capacity + serve.** On the scale cluster (us-west-2, `KUBECONFIG=/tmp/kubeconfig-scale`),
   apply the manifest. Karpenter provisions the p5e/p5en when the pod asks for it. If the
   box does not land on first apply (H200 drought), let the capacity poller fire it.

2. **Smoke test (before the full eval, SE-19).** Confirm: (a) the serve loads — arch
   accepted by v0.23.0, FP4+FP8 mixed weights + 865 GB on one box, TP=8 — and generates one
   completion; (b) `--reasoning-parser deepseek_v4` strips the reasoning so the visible
   content is the extraction JSON / RAG answer (gateway coalesces null content, SE-23). If
   the JSON is truncated, raise the request token ceiling — V4-Pro-Max spends heavily on
   reasoning before the answer (the GLM-5.2 truncation lesson).

   **`VLLM_USE_DEEP_GEMM=1` is REQUIRED** (verified live on 8×H200, 2026-06-30). V4-Pro's
   checkpoint is `ue8m0` block-scaled FP8 (`config scale_fmt=ue8m0`). With DeepGEMM OFF —
   the old DeepSeek-V3.2/GLM-5.2 Hopper guidance — vLLM v0.23.0 falls back to the CUTLASS
   c3x w8a8 path, which cannot dispatch that scale format and dies during KV-cache profiling
   (`dispatch_scaled_mm ... scaled_mm_helper.hpp:17`), *after* a clean 865 GB load. With it
   ON, vLLM logs `Detected scale_fmt=ue8m0; enabling UE8M0 for DeepGEMM` and serves. This is
   the OPPOSITE of the V3.2/GLM guidance — the manifest is already set correctly.

   **Arch support is NOT the blocker:** v0.23.0 accepts `DeepseekV4ForCausalLM`, loads the
   FP4+FP8 checkpoint single-box at TP=8, and produces correct, non-truncated extraction
   JSON. No nightly needed (unlike GLM-5.2). KV headroom is tight — ~17 GiB/GPU → ~129 k
   tokens, ~3.95× concurrency at 32 k — fine for the low-concurrency eval.

3. **Extraction + RAG-collect.** `bash bench/run-deepseek-v4-pro.sh`. Arms the GPU belt,
   applies the manifest, and submits the in-cluster eval Job: scores clean-digital
   extraction + collects RAG answers (`TIERS=clean-digital SKIP_COMMERCIAL=1`, `WORKERS=2`,
   1200 s timeouts for the reasoning + Marlin-FP4 tax), ships log + result to
   `s3://<scale-bucket>/results/`, and releases the GPU on exit. Laptop-independent once
   submitted. Watch with `make status`; harvest with `make quality-results`.

4. **Fixed-judge RAG scoring.** Score the collected RAG answers with the lineup's fixed
   judge (Qwen2.5-VL-72B via `vllm-scale.yaml`) — not V4-Pro judging itself (the self-judge
   bias was ~9 points) — so the RAG number stays comparable.

5. **Cost / latency.** `make bench` drives `loadgen` for peak throughput → $/M output token.
   Expect a reasoning + Marlin-FP4-on-Hopper tax on throughput. **The $/M is a Hopper
   number**; a Blackwell box (native FP4 tensor cores) would be faster and cheaper — state
   that when publishing. Fill `bench/configs/deepseek-v4-pro.json` `instance_hourly_usd` /
   `price_basis` from `describe-spot-price-history` (p5en) at run time.

6. **Capture + fold in.** Add the row to `docs/benchmarks/`, the README results summary,
   and the site writeup, then PR `bench/deepseek-v4-pro` into `public` and publish with
   `scripts/publish-oss.sh`. This unblocks the gated OSS publish (ref-arch delivery state).

## Cost

One 8×H200 box for the run, single-node. Rough estimate ~$60–120 of GPU for serve +
extraction + RAG + loadgen (the 865 GB pull + reasoning/Marlin tax push it above the
Ornith/Nemotron range), plus the one-time ~865 GB weight pull from Hugging Face into node
NVMe.
