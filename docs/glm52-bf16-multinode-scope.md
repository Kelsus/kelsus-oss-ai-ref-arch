# Scope — GLM-5.2 at full BF16 across two machines (the genuine multi-node proof)

**Goal.** Serve `zai-org/GLM-5.2` at its **official BF16 weights (~1.5 TB)** across **2× p5e.48xlarge
(16× H200, 2,256 GB)** wired with EFA — the real "trillion-class model that does not fit one box"
demonstration, on a model that is (a) current and strong (Z.ai, June 2026; MIT; ~753B MoE; rivals
Claude Opus 4.8 on coding), (b) **chat-capable** (so it runs our harness), and (c) needs two machines
**in its own shipped precision** — no contrived BF16 upcast. This is the proof the Kimi-K2.5 run
couldn't deliver (Kimi fit one box at INT4).

## Why GLM-5.2-BF16 is the right model for this

| | GLM-5.2 BF16 | DeepSeek-V4-Pro-Base | Kimi/V3.2 upcast-to-BF16 |
|---|---|---|---|
| Genuinely > 1 box | ✅ 1.5 TB | ✅ 1.6 TB (FP8) | ✅ |
| Official shipped precision (no caveat) | ✅ BF16 is the primary release | ✅ FP8 | ❌ contrived upcast |
| Chat / benchmarkable | ✅ | ❌ base model | ✅ |
| Current / newsworthy | ✅ (newest open flagship) | ✅ | mid |

It's the only candidate that is all three: real precision, real chat model, real "doesn't fit."

## Memory budget (the part that makes it honest)
- 8×H200 = 1,128 GB → one box **cannot** hold the 1.5 TB of BF16 weights. Fact, not framing.
- 2× p5e = 2,256 GB → weights ~1,507 GB (67%), leaving ~750 GB for KV cache + activations.
- GLM-5.2 uses **DSA / IndexShare sparse attention** (compressed KV, like DeepSeek MLA), so even at
  long context the KV stays modest — the 2-node headroom is comfortable for real serving.

## Architecture
- **LeaderWorkerSet (LWS)** — `replicas: 1`, `size: 2` → 1 leader + 1 worker, 8×H200 each.
- **Ray** across the two pods; vLLM shards **TP=8 within a node × PP=2 across nodes** (pipeline
  parallel avoids per-layer cross-node all-reduce — EFA carries the pipeline activations).
- **EFA** for cross-node NCCL. **vLLM v0.23.0** (`GlmMoeDsaForCausalLM` is in the registry — same
  DSA path that served DeepSeek-V3.2). `--reasoning-parser glm45`. GLM-5.2 ships an **MTP** layer →
  optional speculative decoding for throughput.
- In-cluster Service `vllm:8000` unchanged → gateway + harness need zero changes.

## Cluster prerequisites (install once — NONE are present today)
1. **LeaderWorkerSet controller** — `helm install lws oci://registry.k8s.io/lws/charts/lws` (pin version).
2. **EFA device plugin** — `aws-efa-k8s-device-plugin` DaemonSet (tolerate the GPU taint, target p5e).
3. **p5e single-AZ NodePool + EC2NodeClass** — spot, pinned to one AZ, **EFA interfaces enabled** +
   a **cluster placement group**. (Mirror the `gpu-h200` pool; add ENIs/EFA + placementGroup + single-AZ.)
   The `vllm-kimi-k25-multinode.yaml` draft + `kimi-multinode-runbook.md` are the skeleton to adapt.

## Weight staging (the long pole — keep it off the GPU clock)
~1.5 TB BF16. Stage `zai-org/GLM-5.2` → `s3://<scale-bucket>/models/glm-5.2-bf16/` once via a CPU Job
(`hf download` → `aws s3 sync`), **before** any p5e is up. At serve, each node `aws s3 sync` to local
NVMe (both nodes need the full files; TP shards in memory). ~1.5 TB is ~2.5× the Kimi pull — budget hours.

## Bring-up sequence
1. Install the 3 prereqs (GPU-free). 2. Stage weights to S3. 3. Apply the p5e NodePool + the LWS
manifest → watch both pods land on 2 p5e in one AZ, Ray form (2 nodes joined), vLLM load. 4. Smoke:
one `/v1/chat/completions` → coherent completion. 5. Run the eval through the gateway exactly like
every other model (`TIERS=clean-digital`, `RAG_COLLECT=1`) → fixed-judge pass. 6. Teardown: delete
the LWS → Karpenter consolidates → **EC2-verify 0 p5e running**; confirm the dead-man covers LWS
(it scales `deploy/vllm`; an LWS is a different kind — the kill path must delete/scale the LWS).

## Bonus deliverable
Because GLM-5.2 ships **both** FP8 (756 GB, single box — running now) **and** BF16 (1.5 TB, multi-node),
we get a clean **FP8-vs-BF16 same-model quality delta** for free: does the quantization the labs ship
actually cost anything on our workload? That's a genuinely interesting sub-finding, and a strong
companion to the "what it takes to serve it the hyperscaler way" article.

## Cost & the gating risk
- 2× p5e spot ≈ **$36–40/hr** (H200 spot is currently shortage-elevated). A 10–12 h window
  (stage-load + serve + eval) ≈ **$360–480**; well under the **<$1000** gate. On-demand for the pair
  is ~$200/hr → blows the gate, so **spot only**.
- **THE risk is capacity, not the model.** We have already watched H200 spot go scarce for *one*
  node (DeepSeek waited ~30 min; on-demand was also ICE across all AZs at one point). Getting **two
  p5e simultaneously, single-AZ, on spot** is materially harder. Mitigations: pick the AZ with live
  p5e spot at run time; be ready to wait; consider a brief on-demand window only if the gate allows.
- **Abort criteria:** if the 2-node placement won't fill on spot within the window, or projected cost
  > $1000 → fall back to the FP8 single-box GLM-5.2 (already running) and report the multi-node
  attempt honestly, or defer until p5e capacity loosens.

## Open items to confirm at bring-up
- TP=8×PP=2 with a **DSA** model — confirm vLLM v0.23.0 pipelines DSA layers cleanly (new combo for us).
- EFA resource count on p5e.48xlarge; NCCL/EFA env (`FI_PROVIDER=efa`, `NCCL_*`, `GLOO_SOCKET_IFNAME`).
- LWS controller + EFA-plugin versions; EC2NodeClass EFA + placement-group config.
- Dead-man coverage for the LWS object (not just `deploy/vllm`).

## One-line recommendation
Stand up the prereqs + stage weights now (GPU-free, no capacity risk); fire the 2-node window only
once we confirm we can hold two p5e on spot in one AZ. That capacity question — not GLM-5.2 — is the
decision gate.
