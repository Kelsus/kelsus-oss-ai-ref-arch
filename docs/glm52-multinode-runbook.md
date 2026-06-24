# GLM-5.2 BF16 multi-node serve — runbook

Serve `zai-org/GLM-5.2` at full **BF16 (~1.4 TB)** across **2× p5e/p5en (16× H200)** with
LeaderWorkerSet + Ray + EFA. This is the reproducible sequence, with every gotcha learned
from the first real bring-up (2026-06-22) called out. Canonical artifacts:

- `infra/helm/vllm-glm-52-multinode.yaml` — the serve (LWS + Ray, **flat TP=16**, all fixes).
- `infra/helm/multinode-prereqs.sh` — cluster add-ons the serve depends on (idempotent).
- `infra/helm/karpenter-nodepool-h200.yaml` — the `gpu-h200` NodePool (p5e/p5en, 2-node limit).
- `infra/helm/lws-deadman.yaml` — the GPU cost backstop.
- `infra/terraform/envs/scale` (us-west-2) / `scale-east2` (us-east-2) — the cluster IaC.

## Status (2026-06-23)
Infrastructure **proven end-to-end**: the capacity poller lands 2 same-AZ H200 when spot
recovers, Ray forms across both nodes, EFA is up, and the **full 1.4 TB BF16 load completes
on both machines**. The load then hit a real vLLM bug — `GlmMoeDsaForCausalLM` built the DSA
indexer (with `k_norm`) on all 78 layers, but GLM-5.2's IndexShare stores those weights on
only the 21 'full' layers → `ValueError: weights not initialized from checkpoint:
...indexer.k_norm...` for the other 57. This is **independent of TP/PP** — identical under
TP=8×PP=2 and flat TP=16. The fix is the vLLM **image**: commit #45895 "Indexer init skip"
(2026-06-19) builds the indexer only on the 'full' layers, and landed four days AFTER the
v0.23.0 tag — so the manifest now pins the first nightly past it (fix #10). Fix applied; the
capacity poller is re-armed to retry on the next spot window and auto-smoke-tests on Ready.

## Bring-up sequence
```bash
export AWS_PROFILE=kelsus-dev
ENV=scale; REGION=us-west-2; CTX=west2            # or: scale-east2 / us-east-2 / east2
CLUSTER=kelsus-refarch-scale                       # or: ...-east2

# 1. Cluster (declarative — VPC, EKS, Karpenter IAM/queue, S3 model bucket, pod-identity)
make tf-${ENV}-apply                               # tofu -chdir=infra/terraform/envs/$ENV apply
aws eks update-kubeconfig --name $CLUSTER --region $REGION --alias $CTX

# 2. Karpenter controller (+ base nodepool)
CLUSTER=$CLUSTER TF_DIR=infra/terraform/envs/$ENV AWS_REGION=$REGION infra/helm/karpenter-install.sh

# 3. Multi-node prereqs (NVIDIA plugin, EFA plugin+toleration, LWS controller, gpu-h200 pool, dead-man)
CTX=$CTX AWS_REGION=$REGION TF_DIR=infra/terraform/envs/$ENV infra/helm/multinode-prereqs.sh

# 4. Stage weights to the cluster's IN-REGION bucket (GPU-free; download is the long pole)
make seed-model MODEL=zai-org/GLM-5.2 ...          # -> s3://<bucket>/models/glm-5.2-bf16/
#   then VERIFY no small text files were stored gzip-compressed (the manifest decompresses
#   in-pod as a safety net, but staging them raw is cleaner):
#   aws s3 cp s3://<bucket>/models/glm-5.2-bf16/config.json - | head -c2 | xxd   # must NOT be 1f8b

# 5. Arm the serve (substitute the in-region bucket)
BUCKET=kelsus-refarch-models-${ENV}-<acct>
sed "s#__BUCKET__#$BUCKET#g" infra/helm/vllm-glm-52-multinode.yaml | kubectl --context $CTX apply -f -
#   -> LWS Pending ($0) until 2× same-AZ H200 spot land; dead-man bounds any idle serve.

# 6. When it serves: smoke, then eval through the gateway exactly like every other model,
#    then DELETE the LWS + the GPU nodeclaims and EC2-verify 0 p5e/p5en running.
```

## The fixes — why each line in the manifest/bootstrap exists
1. **NVIDIA device plugin is NOT in the AMI.** EKS's NVIDIA AL2023 AMI ships drivers but not the
   k8s device plugin; without it a GPU node is Ready yet advertises no `nvidia.com/gpu`. (bootstrap step 1)
2. **EFA plugin must tolerate the `nvidia.com/gpu` taint** or its daemonset is DESIRED=0 on the GPU
   nodes and `vpc.amazonaws.com/efa` is never advertised → pods Pending forever. (bootstrap step 2)
3. **gpu-h200 NodePool limit must be ≥384 vCPU** (TWO p5e), not 192 — else only one node ever launches
   and the 2-node LWS never completes. (`karpenter-nodepool-h200.yaml`)
4. **Ray may not be in the vLLM image** (optional multi-node extra) → install a pinned `ray==2.55.1`
   on both pods ONLY if the image ships none (`command -v ray || pip install ray==2.55.1`), so a
   bundled ray matching the build is preserved and both pods still agree on a version. Under the old
   `set -e`, a missing ray (`ray: command not found`, exit 127) crashed the container into a re-pull loop.
5. **The `vllm` Service must be headless + `publishNotReadyAddresses: true`** so the worker can resolve
   `vllm-0.vllm.default` (LWS_LEADER_ADDRESS) before the leader is Ready. A ClusterIP service breaks
   per-pod DNS; without publishNotReady the not-Ready leader's A record never publishes (deadlock).
6. **Small text files (config.json, *.index.json, ...) were staged gzip-compressed** (no S3
   Content-Encoding) → `aws s3 sync` pulls raw gzip bytes and vLLM fails to parse config.json. The
   manifest decompresses non-safetensors files in-pod (`1f 8b` magic → `gzip -dc`). safetensors are raw.
7. **`hostPath` (node NVMe RAID0), not `emptyDir`, for `/models`** — survives a pod restart so a crash
   doesn't re-pull the 1.4 TB (~50 min / ~$30 each). The `df` guard aborts if the path isn't the big
   disk (never fills the 120 GB root EBS). `/var/lib/kubelet/...` is confirmed on the RAID0.
8. **`set -uo pipefail`, NOT `-e`** + bounded retries on sync/ray → a transient non-zero exit can't
   crash the container and wipe weights.
9. **`ray status` (CLI) for the 16-GPU wait gate, NOT `python ray.init()`** — repeated `ray.init()`
   churns Ray driver sessions and invalidates vLLM's actor handles (`ActorHandleNotFoundError`).
10. **The vLLM IMAGE must post-date #45895 — this is the real `k_norm` fix.** GLM-5.2's DSA uses
    IndexShare: only the 21 'full' layers (`config.indexer_types` — layers 0,1,2,6,10..74) own a
    sparse-attn indexer with `k_norm`; the other 57 'shared' layers reuse it and store NO indexer
    weights. vLLM v0.23.0 builds the indexer on ALL 78 DSA layers regardless, so loading BF16 dies:
    `ValueError: weights not initialized from checkpoint: ...indexer.k_norm...` for the 57 shared
    layers. (Single-box FP8 loaded only because that release ships indexer weights duplicated on every
    layer.) This is **independent of TP/PP** — identical under TP=8×PP=2 and flat TP=16, so the earlier
    "use TP=16 to fix k_norm" was wrong. Commit **#45895 "Indexer init skip" (2026-06-19)** builds the
    indexer only on 'full' layers; it landed AFTER the v0.23.0 tag (2026-06-15), so the manifest pins
    `vllm/vllm-openai:nightly-a346d589…` (first nightly past #45895 + its follow-up #46199).
    `--hf-overrides '{"index_topk_pattern":"FFFSSSF…"}'` (78-char F/S derived from `indexer_types`)
    states the skip explicitly; vLLM also derives it from `index_topk_freq`/`index_skip_topk_offset`.
11. **Flat TP=16 (the parallelism, NOT the k_norm fix).** Keeps every layer whole on every rank;
    GLM-5.2 divides cleanly: heads 64÷16=4, experts 256÷16=16, hidden 6144÷16. Use
    `--distributed-executor-backend ray` so vLLM spreads the 16 ranks across both nodes (without it the
    mp executor rejects world-size 16 > 8 local GPUs). Cross-node TP all-reduce rides EFA every layer
    (heavier than PP; PP=2 is also viable now the k_norm fix is in — a throughput option, not required).

## Cost & capacity
- 2× p5e/p5en spot ≈ **$40/hr** (≈$20/node·hr, H200 shortage-elevated). A full first run
  (≈50 min pull on hostPath + cross-node load + eval) ≈ **$120–180**.
- **Capacity is the gating risk**, not the model. us-east-2 had instant 2-node spot; us-west-2 took
  hours. The serve pulls weights **in-region** — so serve where the weights are staged (or stage them
  to the serve region first). Cross-region pull works (grant + ~$56 transfer) but is slower/messier.
- Dead-man (`lws-deadman.yaml`) deletes the LWS on: lone-leader (worker not landing) with the GPU
  node up ≥15m; not-Ready with the GPU **node** up ≥75m; or Ready ≥3h. It ages off the NODE, not the
  pod — `RecreateGroupOnPodRestart` resets pod startTime on every crash, so a tight crash-loop once
  burned ~6h/~$250 under a pod-age threshold before this was fixed. The poller auto-smoke-tests the
  serve on Ready (captures one real completion + stamps `glm.kelsus/smoked`) before the 3h teardown.
- Poller liveness: a watchdog CronJob (in `glm-capacity-poller.yaml`) checks every 10m that the poller
  is actually firing — unless deliberately suspended, it flags a stall when `lastScheduleTime` is >25m
  old, kicks one manual run to bridge it, and stamps a verdict you can read at a glance:
  `kubectl get cronjob glm-poller -o jsonpath='{.metadata.annotations.glm\.kelsus/liveness}'` →
  `healthy` | `paused` | `STALLED`. (Added after a silent poller stall once hid for hours.)
