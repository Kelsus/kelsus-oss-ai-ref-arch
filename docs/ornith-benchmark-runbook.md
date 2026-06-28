# Ornith-1.0-397B benchmark runbook

Adds `deepreinforce-ai/Ornith-1.0-397B` to the same-weights benchmark. Work lands on
the `bench/ornith` branch and folds into `public` when the numbers are in.

## What Ornith is

- **397B MoE** (`qwen3_5_moe`: 512 experts, 10 active per token), post-trained on
  Gemma 4 + Qwen 3.5.
- **Multimodal (vision + text)** → runs the full extraction tiers (medical + commercial,
  clean through degraded), like Qwen3-VL.
- **Reasoning model** (emits `<think>…</think>`) → `--reasoning-parser qwen3`.
- **BF16 is the best version** (~794 GB). The "9 quantized" variants on the card are
  consumer GGUF/Ollama builds, not serving-grade.
- **MIT, open-weight, self-host only** (not on Bedrock) → a Layer-A self-hosted row,
  no same-weights Bedrock twin. 262K context.

## Serving

- `infra/helm/vllm-ornith.yaml`: single 8×H200 box (`gpu-h200` nodepool, p5e/p5en),
  TP=8, BF16, `--reasoning-parser qwen3`, image-only multimodal, `--max-model-len 32768`.
- vLLM **v0.23.0** (our pinned stable) registers `Qwen3_5MoeForConditionalGeneration`
  (verified at source), so no nightly is needed — unlike GLM-5.2.
- One node, not two same-AZ, so capacity is far easier than the GLM multi-node run.
  Single-node spot has scored 1–6 versus 1–2 for pairs. Use the existing poller if the
  box does not land on the first apply.

## Run sequence

1. **Capacity + serve.** On the scale cluster (us-west-2, `KUBECONFIG=/tmp/kubeconfig-scale`),
   apply the manifest. Karpenter provisions the p5e when the pod asks for it; the
   `lws-deadman` does not apply (single-box Deployment, no LWS), so the cost guards are
   the nightly gpu-off CronJob and `make gpu-pause`.

2. **Smoke test (before the full eval, SE-19).** One real vision extraction returns
   parseable JSON, and `--reasoning-parser qwen3` strips the `<think>` block so the
   visible content is the answer. If the JSON is truncated, raise the request token
   ceiling: a reasoning model spends tokens on `<think>` before the answer (the GLM-5.2
   lesson). The card also lists `--tool-call-parser qwen3_xml` for agentic tool use; add
   it (with `--enable-auto-tool-choice`) only if the claims-intake agentic runs need
   native tool calls. Extraction and RAG do not.

3. **Extraction + RAG-collect.** `bash bench/run-ornith.sh`. This arms the GPU belt,
   applies the manifest, and submits the in-cluster eval Job: it scores extraction across
   all tiers + the FATURA commercial set, collects RAG answers, ships log + result to
   `s3://<scale-bucket>/results/`, and releases the GPU on exit. Laptop-independent once
   submitted. Watch with `make status`; harvest with `make quality-results`.

4. **Fixed-judge RAG scoring.** Score the collected RAG answers with the same judge as
   the rest of the lineup, Qwen2.5-VL-72B served via `vllm-scale.yaml` — not Ornith
   judging itself (the self-judge bias was about 9 points). This keeps Ornith's RAG
   number comparable.

5. **Cost / latency.** `make bench` drives `loadgen` for peak throughput → $/M output
   token. Expect a reasoning-model tax on throughput, like DeepSeek-V3.2 and GLM-5.2.

6. **Capture + fold in.** Add Ornith's row to `docs/benchmarks/`, the README results
   summary, and the site writeup, then PR `bench/ornith` into `public` and publish with
   `scripts/publish-oss.sh`.

## Cost

One 8×H200 box for the run. Rough estimate ~$50–100 of GPU for serve + extraction + RAG
+ loadgen, plus the one-time ~794 GB weight pull from Hugging Face into node NVMe.
