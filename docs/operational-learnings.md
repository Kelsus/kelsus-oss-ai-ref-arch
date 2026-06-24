# Operational Learnings (running log)

Captured as we build, while fresh. At the **publish sprint** the `[PUBLIC]` entries
are curated into Section 10 of [`architecture.md`](architecture.md) — *What worked /
What we'd do differently / Sharp edges*. `[INTERNAL]` entries are our local
toolchain quirks; they stay here / in build notes and **do not** go in the public doc.

Each sharp edge: **Symptom → Root cause → Fix → Generalizes?** Error strings are
kept verbatim on purpose — someone hits the same error, searches it, finds us.

> Tag test for `[PUBLIC]`: *would a reader deploying this in their own AWS account
> plausibly hit it?* If it's specific to our laptop, it's `[INTERNAL]`.

---

## Sharp edges — `[PUBLIC]`

### SE-1 · NVIDIA device plugin never advertises the GPU (DESIRED=0)
- **Symptom:** GPU node is `Ready`, has the GPU, the device-plugin DaemonSet rolls out "successfully" — but `nvidia.com/gpu` is never allocatable and the DaemonSet shows `DESIRED 0`.
- **Root cause:** the upstream `nvidia-device-plugin` Helm chart **hard-codes** a nodeAffinity requiring NFD/GFD labels (`feature.node.kubernetes.io/pci-10de.present`, `nvidia.com/gpu.present`, …). With no NFD/GFD installed, zero nodes match → `DESIRED 0`. `--set affinity={}` does **not** override it (the chart templates it regardless of values).
- **Fix:** label the GPU node group `nvidia.com/gpu.present=true` (what the chart's default affinity matches) **and** give the plugin a toleration for the GPU taint. Managed-node-group label changes only affect *new* nodes, so existing nodes need a one-time `kubectl label node … nvidia.com/gpu.present=true` bridge.
- **Generalizes?** Yes — anyone using the upstream chart on EKS managed node groups without NFD/GFD.

### SE-2 · Cross-node pod traffic to low ports silently times out
- **Symptom:** a pod reaches other services on `:8000` / `:5432` fine, but **times out** (not "refused") connecting to a service on `:80` — and only when the two pods are on **different nodes**. `URLError: <urlopen error [Errno 110] Connection timed out>`.
- **Root cause:** the EKS managed-node-group security group's self-rule allows node-to-node traffic only on the **ephemeral range (1025–65535) + DNS (53)**, not arbitrary low ports. Same-node pod-to-pod bypasses the SG (works); cross-node to `:80` is dropped → timeout. It hides until the callee lands on another node/AZ.
- **Fix:** run services on **high ports (≥1025)** — e.g., TEI embeddings on `:8080` with `Service :80 → targetPort :8080`. (Alternative: add an explicit node-SG ingress rule for the low port.)
- **Generalizes?** Yes — any `<1025` service with the default community-module node SG.

### SE-3 · A Service name can poison an app's own env var (`VLLM_PORT`)
- **Symptom:** vLLM crash-loops at engine init: `ValueError: VLLM_PORT 'tcp://172.20.x.x:8000' appears to be a URI. This may be caused by a Kubernetes service discovery issue`.
- **Root cause:** Kubernetes injects legacy per-Service env vars (`<SERVICENAME>_PORT=tcp://ip:port`, `_SERVICE_HOST`, …) into every pod in the namespace. A Service named `vllm` injects `VLLM_PORT`, which vLLM reads as *its own* port setting.
- **Fix:** `enableServiceLinks: false` on the pod spec (kills the whole class of collisions), or rename the Service so it doesn't collide.
- **Generalizes?** Yes — any app whose config env var collides with `<SERVICENAME>_PORT/_HOST`. Bites vLLM specifically.

### SE-4 · Single-GPU rollout deadlocks under the default strategy
- **Symptom:** after editing the GPU Deployment, the new pod stays `Pending` forever (`Insufficient nvidia.com/gpu`) while the old pod keeps running.
- **Root cause:** default `RollingUpdate` (maxSurge 1 / maxUnavailable 0) starts the new pod *before* terminating the old — but on a one-GPU node the new pod can't get the GPU the old one still holds → deadlock.
- **Fix:** `strategy: type: Recreate` for single-accelerator deployments (terminate old, then start new). Accept the brief downtime.
- **Generalizes?** Yes — any Deployment whose replicas contend for a scarce, indivisible per-node resource (a whole GPU).

### SE-5 · Resource *requests* (not usage) block scheduling on small nodes
- **Symptom:** a tiny service (CPU reranker) stuck `Pending` with `FailedScheduling … Insufficient cpu`, despite the model being small.
- **Root cause:** it requested a full core; the small nodes (m6i.large, 2 vCPU) were already ~64% CPU-committed by *requests*. Scheduling is about requests, not actual utilization.
- **Fix:** right-size requests (e.g., `250m` for a burstable CPU service) and let it burst; or add node capacity. Don't over-request "to be safe."
- **Generalizes?** Yes — general capacity-planning lesson; acute on small nodes.

### SE-6 · GPU vanishes after a node-group scale 0→1 (stale launch template + device-plugin affinity)
- **Symptom:** after pausing/resuming (`gpu-resume` scales the node group 0→1), the new GPU node is `Ready` but `nvidia.com/gpu` never becomes allocatable; the device-plugin daemonset shows `DESIRED=0`.
- **Root cause (two layers):** (1) the device plugin's stock nodeAffinity requires `nvidia.com/gpu.present=true` (an NFD/GFD label) — and `helm --set-json affinity={}` does **not** clear it. We instead set `nvidia.com/gpu.present=true` as a node-group label. (2) But a node group scaled via the AWS CLI is born from the launch template as it existed at *group creation* — a label added to the `.tf` later isn't on the node until `terraform apply` rolls the launch template. So the resumed node lacked the label.
- **Fix:** `terraform apply` after any node-group label change (durable); `kubectl label node … nvidia.com/gpu.present=true --overwrite` as an immediate bridge. Durable-est: install NFD so the stock affinity just works.
- **Generalizes?** Yes — any node-group label/launch-template change made out-of-band of the node lifecycle, plus the device-plugin-wants-a-label pattern.

### SE-8 · A fresh AWS account cannot launch spot instances (missing service-linked role)
- **Symptom:** every spot launch fails; Karpenter surfaces it as `UnfulfillableCapacity`, indistinguishable at a glance from a capacity drought. Buried in fleet errors: `AuthFailure.ServiceLinkedRoleCreationNotPermitted ... service-linked role for EC2 Spot`.
- **Root cause:** the account-global `AWSServiceRoleForEC2Spot` role is created lazily on first spot use by a sufficiently-privileged caller. Karpenter's node role can't create it, so an account that has never run spot can't start now.
- **Fix:** one-time, with admin credentials: `aws iam create-service-linked-role --aws-service-name spot.amazonaws.com`. The very next spot attempt landed.
- **Generalizes?** Yes — any first spot use in a fresh account via an automation role. Looks exactly like ICE; check fleet errors for AuthFailure before blaming capacity.

### SE-9 · The kill switch must not depend on a pullable third-party image
- **Symptom:** the nightly scale-to-0 CronJob fired exactly on schedule — then sat `ImagePullBackOff` for 7 hours on `bitnami/kubectl:1.31` (registry deprecated the tags) while a spot GPU box idled at ~$9/hr.
- **Root cause:** a safety-critical path depended on an unpinned third-party image, and the executor was never test-fired (only the schedule was verified).
- **Fix:** remove the dependency — PATCH the Kubernetes scale subresource directly with the pod's service-account token from an image already proven pullable in-cluster (`python:3.12-slim`). And **test-fire the executor** (`kubectl create job --from=cronjob/...`) as part of installing any dead-man.
- **Generalizes?** Yes — break-glass mechanisms inherit all the supply-chain fragility of their tooling. Minimize the kill path's dependencies; verify it end-to-end, not just its trigger.

### SE-10 · Long `kubectl wait`/`rollout status` watches die silently
- **Symptom:** orchestration chains hung or aborted mid-run: `rollout status` stuck on a superseded revision after a mid-wait spec change; `kubectl wait` killed by `http2: client connection lost` watch-stream drops.
- **Fix:** poll (`get` in a loop with timeouts) instead of holding multi-hour watches; make every chain stage idempotent and resumable; never chain irreversible steps (scale-to-0) behind a fragile wait.
- **Generalizes?** Yes — applies to any long-lived Kubernetes watch through ELBs/NAT.

---

### SE-14 · A CPU-starved single-replica gateway returns empty bodies under load (the DeepSeek n=4)
- **Symptom:** DeepSeek-V3.1 quality runs completed only ~4–22 of 134 extractions and ~5 of 250 RAG questions. The captured error summary (added after the first false-success) showed `JSONDecodeError: Expecting value: line 1 column 1 (char 0)` ×357 — i.e. **empty HTTP response bodies**, not timeouts and not crashes (gateway had 0 restarts; vLLM was healthy enough to hit 2,274 tok/s in the perf step).
- **Root cause:** the eval drives the **gateway**, not vLLM directly. At run time the gateway was at **1 replica / 1 uvicorn worker**, CPU-starved on oversubscribed 2-vCPU nodes. Under sustained concurrent *slow* (reasoning-model) requests it dropped connections with empty bodies. The scorer had **no retry**, so every transient empty became a permanently dropped item — and the difficulty was invisible because clean-digital extraction *looked* fine on the handful that got through.
- **Fix (defense in depth, all cheaply validatable without the flagship GPU):** (1) scorer `_post_json` retry+backoff treating empty-body/5xx as retryable; (2) gateway runs **2 uvicorn workers** with `--limit-concurrency` (overflow → retryable 503, never a dropped/empty connection); (3) the harness fails loud + quarantines + tees logs to S3, which made this diagnosable at all. **The real root cause turned out to be a psycopg2 connection leak — see SE-15.**
- **REVERTED mis-step (see SE-16):** an earlier version of this fix also made the gateway *tolerate the GPU taint* so a replica could borrow the GPU node's CPU. That was wrong and dangerous — a gateway pod on the GPU node keeps it non-empty, so it never consolidates and the dead-man (which only scales vLLM to 0) cannot bring the box down. Gateway stays on CPU nodes, period.

### SE-15 · psycopg2 `with conn` does NOT close the connection — the actual RAG-under-load failure
- **Symptom:** RAG requests through the gateway returned 500s / empty bodies once a run sustained load; extraction (no DB) was unaffected.
- **Root cause:** `with psycopg2.connect(...) as conn:` closes the **transaction**, not the **connection** — every `/rag/query` leaked a Postgres connection. Under concurrency the pgvector pod hit `max_connections` and refused new ones, so the gateway's DB call failed and the handler returned an error/empty body. This (not gateway CPU) was the dominant cause of the DeepSeek n=4.
- **Fix:** wrap in `contextlib.closing(psycopg2.connect(...))` so the socket actually closes each call. (Long-term: a connection pool.) Verified: extraction 134/134 and the DB path stable under WORKERS=24 stress.
- **Generalizes?** Yes — a classic psycopg2 footgun. `with conn` ≠ close. Any per-request `connect()` without explicit close leaks under load.

### SE-16 · Cost-control mechanisms must not be defeatable by unrelated pods (the $50–90 dev burn)
- **Symptom:** "cheap dev validation" silently ran the **72B on an 8×A100 p4de spot (~$15–20/hr)** instead of a 7B on g6e (~$1.50/hr), and the node refused to consolidate; deleting its nodeclaim spawned a replacement. ~$50–90 wasted across three p4de instances.
- **Root causes, compounding:** (a) the dev `vllm` Deployment had been overwritten to request **8 GPUs**, and the validate script ran `gpu-resume` without re-asserting the 1-GPU 7B manifest — so a 1-GPU intent launched an 8-GPU box; (b) the dev cluster had **`gpu-h100`/`gpu-scale` NodePools it never should have had**, so Karpenter *could* satisfy the 8-GPU request; (c) the gateway's GPU-toleration (SE-14 mis-step) parked a pod on the GPU node so it never went empty → consolidation + dead-man both defeated.
- **Fix:** deleted dev's `gpu-h100`/`gpu-scale` NodePools (dev can only launch g6e.xlarge now — an 8-GPU pod just stays Pending, which is *free*, instead of burning); reverted the gateway GPU-toleration; restored the dev 7B/1-GPU manifest; always re-assert the model manifest before resume, never trust the live Deployment spec.
- **Generalizes?** Yes, two rules: (1) **a cost guardrail you can accidentally bypass isn't a guardrail** — cap blast radius structurally (no big-GPU NodePool where big GPUs aren't wanted, so the worst case is a free Pending pod); (2) **resume from a known manifest**, never from whatever the cluster happens to hold.
- **Generalizes?** Yes — any reverse-proxy/gateway in front of an LLM. Slow backends turn modest client concurrency into connection exhaustion; the client must retry and the proxy must shed load explicitly (503) rather than drop. And: **reproduce gateway-concurrency bugs on cheap hardware** — the failure is load-shaped, not flagship-specific, so it does not require an H100 to fix or verify.

### SE-19 · Serving a quantized frontier MoE needs the quantizer's EXACT vLLM version + patches — `[PUBLIC]`
- **Symptom:** DeepSeek-V3.1-AWQ served fine under light load (smoke, ~6s answers) but vLLM went unreachable / crash-looped / exited under the sustained benchmark load — ~9 failed attempts across days, surfacing as gateway 500s, connection-refused, and engine restarts. Every other model in the sweep ran first try.
- **Root cause:** we ran the quant on `vllm/vllm-openai:latest` **with `--enable-expert-parallel`** — a configuration the model card explicitly warns against and the vLLM issue tracker documents as crashing MoE under load ([#43648](https://github.com/vllm-project/vllm/issues/43648), [#28887](https://github.com/vllm-project/vllm/issues/28887)). The EP flag had been added as a workaround for a *different* model (Qwen3-FP8 block-quant TP sharding, SE-11) and wrongly carried over.
- **Fix:** follow the quantizer's recipe verbatim — **vLLM 0.9.2** (pinned; not `latest`), `transformers==4.53.0`, the two required patch files (`awq_marlin.py`, `deepseek_v2.py` pulled from the HF repo at container start), TP=8, `--gpu-memory-utilization 0.8`, `--swap-space 16`, `--max-num-seqs 512`, and **no expert parallelism**. Result: a clean, complete run (134/134 extraction, 250/250 RAG, 0 vLLM restarts). Config lives in `infra/helm/vllm-deepseek.yaml`.
- **Generalizes?** Strongly. For quantized community checkpoints, the quantizer's stated vLLM version + patches are not optional — `latest` is frequently incompatible, and the failure mode is load-dependent so it hides in light testing. Pin the version, apply the patches, and don't blindly reuse one model's serving flags on another.

### SE-20 · "In-cluster" must include the WAIT, and a global dead-man must not kill in-progress runs — `[PUBLIC]`
- **Symptom:** a Kimi run (547 GB download) died with no result and no error. Two compounding causes: (1) the global nightly dead-man (06:00 UTC) scaled vLLM to 0 *mid-download* — it can't tell "stranded idle GPU" from "legit long run loading"; (2) the orchestrator's `deploy → poll-until-vLLM-serves → submit-eval` loop ran **on the laptop**, which slept during the ~1–2 h download, so the eval Job was never submitted and nothing in-cluster survived.
- **Subtle trap:** the eval *execution* was in-cluster (correct), so runs were described as "disconnect-safe" — but the **pre-submit window** (deploy + wait-for-serve) was laptop-bound. Fine for models that serve in minutes; fatal for a multi-hour download.
- **Fix:** (a) move the wait **into the cluster** — the eval Job polls `vllm/health` itself (up to 3.5 h) before scoring, so the laptop only does instant `kubectl apply`s then can sleep; (b) make the nightly dead-man **conditional** — skip scaling down if the `bench-quality` eval Job is active; (c) keep a **per-run in-cluster deadline Job** as the primary cost belt during a run. No mechanism kills a live run; cost is still bounded if one hangs.
- **Generalizes?** Yes. "In-cluster/autonomous" has to cover the *entire* critical path including waits — a laptop-side poll loop is a hidden single point of failure. And any always-on cost guard must defer to in-progress work, or it becomes a friendly-fire risk.

### SE-21 · A model's custom tokenizer can need a Python dep the serving image lacks — crash AFTER the multi-hour download — `[PUBLIC]`
- **Symptom:** Kimi-K2-Instruct (8×H200) finished its full 547 GB download and loaded config, then crash-looped on every boot at tokenizer init: `ImportError: blobfile is not installed`. The in-cluster eval Job waited patiently for a vLLM that would never come up.
- **Root cause:** Kimi K2 ships a tiktoken-based BPE tokenizer (`tokenization_kimi.py`) that imports `blobfile` to read its vocab; the stock `vllm/vllm-openai:v0.10.0` image doesn't bundle it. The failure is *post-download* and deterministic, so it burns the whole expensive download before failing — and looks like a serve timeout, not a missing dep, until you read the crash log.
- **Fix:** override the container entrypoint to `pip install --no-cache-dir blobfile && exec python3 -m vllm.entrypoints.openai.api_server …`. Result: zero restarts for the full run. (Rolling the deploy to apply this re-downloads the weights — an `emptyDir` can't survive pod replacement; a PVC/hostPath cache would avoid that.)
- **Generalizes?** Yes — `--trust-remote-code` models can pull custom tokenizer/model code with undeclared Python deps. Read the crash log before assuming a capacity/timeout problem, and prefer a pre-baked image (or a cached weights volume) so the fix doesn't cost a re-download.

### SE-22 · A "fixed judge" is only fixed if its image is version-pinned — `latest` silently re-scores everything — `[PUBLIC]`
- **Symptom:** re-running the single-fixed-judge RAG pass to add a new model, every previously-scored model dropped 6–12 pts uniformly (e.g. GLM 45.6%→36.4%, DeepSeek 43.2%→36.4%). The reproduce-check — same judge, temp=0, identical collected answers — failed.
- **Root cause:** the judge manifest pinned `vllm/vllm-openai:latest`, which had rolled forward to a newer vLLM (v0.23). Same judge *weights*, different serving stack → a uniformly stricter scoring regime. Absolute numbers across the two runs were silently incomparable.
- **Fix:** pin the judge image (`vllm-scale.yaml` → `v0.23.0`) and treat the all-models-in-one-pass run as the authoritative baseline; never mix numbers across judge-stack versions. The *within-run* comparison stays valid (one judge, one pass), which is what the leaderboard needs.
- **Generalizes?** Strongly, and it's the LLM-as-judge analogue of SE-19: any cross-run comparison against a model — judge, scorer, embedder — requires the model *and its runtime* to be version-locked. An unpinned `latest` makes "comparable" an illusion.

### SE-23 · A vLLM `--reasoning-parser` returns `content: null` — the gateway assumed a string and crashed — `[PUBLIC]`
- **Symptom:** the GLM-4.7 (reasoning model) self-hosted eval failed twice — the gateway returned HTTP 500 ("Internal Server Error", a 21-byte body) on ~100 of 384 requests, dropping extraction/RAG below the completeness floor → run quarantined. Concurrency was a red herring: WORKERS=4 produced *more* errors (108) than WORKERS=16 (96).
- **Root cause:** a reasoning model served with `--reasoning-parser` splits output into `reasoning_content` (the thinking) and `content` (the answer), and returns **`content: null`** when reasoning consumes the whole `max_tokens` budget. The gateway passed that `None` straight into `_strip_reasoning()` → `TypeError: expected string or bytes-like object`. Two factors compounded: the direct `["content"]` access assumed a string (true for every prior model, not for this shape), and `LLM_MAX_TOKENS=1024` was too low for GLM's reasoning, making null content frequent rather than rare.
- **Why it slipped past SE-1..22 (not a regression):** a *latent* fragility newly **exposed**, not introduced. The prior reasoning model (DeepSeek-V3.1) was served **without** a reasoning-parser, so its content was always a string (`<think>` tags the gateway stripped) — no earlier model ever emitted null content. The Bedrock code path survived the same eval because it joins text blocks into `""`, never `None`; this was local-serving-only.
- **Fix:** gateway coalesces `content → reasoning_content → ""` (never None); `_strip_reasoning` guards empty input; raise `LLM_MAX_TOKENS` to 8192 for reasoning models so the answer actually materializes. Non-reasoning models (Qwen3-VL) were unaffected and passed first try.
- **Generalizes?** The class is "new model → new response shape → old code only ever tested against the old shape." Bugs cluster at the boundary of what's been *exercised*: a mature harness pointed at a genuinely new model or serving profile (reasoning-parser, tool-parser, new multimodal shape) will surface new edges even after many fixes — that's expected, not a backslide. Parse provider responses defensively (null/empty/missing fields) by default, and treat each new serving profile as a new code path to validate, not a drop-in.

### SE-24 · A reasoning model at `LLM_MAX_TOKENS=1024` truncates the *answer*, not the *thinking* — and shared gateway config silently re-introduces it — `[PUBLIC]`
- **Symptom:** GLM-5.2 self-hosted extraction came back **56.1%** with a dead-giveaway **uniform 57.5% on every field** (patient_name = payer_name = … = num_line_items). RAG answers from the same run were fully coherent — so the model served fine; extraction alone was broken.
- **Root cause:** the gateway's `LLM_MAX_TOKENS` was **1024**. A thinking model emits reasoning *first*, then the answer; at a 1,024-token ceiling the reasoning ate the budget and the JSON answer was truncated/never emitted → unparseable on ~43% of invoices (the ~57% that fit parsed perfectly → uniform 57.5%). The 1024 wasn't intended — `managed-sweep.sh` sets `LLM_MAX_TOKENS=1024` per managed model and **clears it on exit** (→ gateway default), so a *later self-hosted* reasoning run silently inherited the small budget. Same family as SE-23, different trigger: there the budget produced `content:null`; here it truncated a non-null but incomplete answer.
- **Fix:** raise `LLM_MAX_TOKENS` to **16,384** for self-hosted reasoning runs; GLM-5.2 re-ran at **97.0%** with the normal varied per-field profile (NPI the lone weak field). Thinking stayed **on** — consistent with the rest of the lineup; disabling it would have been a different, inconsistent measurement.
- **Generalizes?** Two durable rules. (1) **The uniform-per-field test:** identical F1 across unrelated fields is a *parse/serving* failure, never a *quality* signal — a real capability gap is uneven. (2) **Shared mutable serving config is a hazard across run types:** any knob one runner sets-and-clears (here `LLM_MAX_TOKENS`) can silently mis-configure the next; pin reasoning-model budgets at the manifest/job level, not on the always-on gateway.

## What worked — `[PUBLIC]`

- **One stack module, two envs (`dev`/`scale`), values-only difference.** dev applied cleanly; `scale` validates identically. The "values-flip" we promise customers held in practice.
- **One vision-language model (Qwen2.5-VL) served text *and* vision** on a single GPU — chat, RAG, digital-PDF extraction, and image/scanned extraction, no separate OCR engine.
- **Embeddings + reranker on CPU (TEI)** kept the lone GPU dedicated to the LLM — clean resource separation, no GPU contention.
- **pgvector (Postgres) was trivial** to stand up and query (`<=>` cosine) — no separate vector DB needed at this scale.
- **Throughput scaled cleanly to 64 concurrent** — 2,375 tok/s aggregate, 0 errors, TTFT still ~150 ms, on a single L40S serving a 7B model; no plateau at 64 → headroom remains. Single-stream 49 tok/s. (`docs/benchmarks/`.)
- **The two-axis model sweep was decision-useful.** Non-obvious finding: a *vision* model is a worse *pure-text* extractor than its text-only sibling at equal cost (Qwen2.5-VL 87.5% vs Qwen2.5-7B 99% extraction F1) — pay for vision only when inputs need it. And "cheaper" didn't mean "much worse" (Phi-3.5-mini: cheapest/fastest, still 92.7%). (`docs/benchmarks/dev-sweep/COMBINED.md`.)

### SE-7 · Long-running evals must not depend on a laptop session (the overnight GPU burn)
- **Symptom:** an evening eval run died silently when the operator's AWS SSO token (8 h) expired — the `kubectl port-forward` tunnels dropped, requests hung, the run never completed, and the GPU billed all night because the "scale down when done" step never fired.
- **Root cause:** the laptop was in the control loop: the eval drove in-cluster services through local tunnels, under short-lived human credentials, with the cost-stop chained to the run finishing.
- **Fix (two independent layers):** (1) run evals as **in-cluster Jobs** with **EKS Pod Identity** for S3 — once submitted, no laptop, tunnel, or SSO token is involved; results land in S3, logs persist via `ttlSecondsAfterFinished`. (2) a **GPU dead-man's switch** — EventBridge Scheduler force-scales the GPU node group to 0 nightly regardless of what any run is doing. Never chain a cost-stop to a run completing.
- **Generalizes?** Yes — any GPU workflow driven from a workstation with expiring credentials. Design rule: *the cluster does the work; the laptop only submits.*

## What we would do differently — `[PUBLIC]`

- **Give the VL model its own GPU node.** Sharing one L40S forced a single-model compromise; in prod, separate the vision and text serving (or use GPU time-slicing deliberately).
- **Ship the gateway as a pinned, pre-built ECR image**, not `pip install` at pod start. The ConfigMap+pip approach is great for the dev loop, wrong for prod (slow start, unpinned deps, egress at runtime).
- **Exercise the no-egress posture in dev too.** We left NAT on in dev for convenience; the sovereign posture (VPC-endpoints-only, no NAT) is only in `scale`. Running it in dev would catch egress assumptions earlier.
- **Right-size requests from day one** (see SE-5) rather than discovering it via a `Pending` pod.
- **RAG quality needs a real judge, not a keyword proxy.** Our fact-coverage + grounding proxy saturated at 100% across all three models — it didn't differentiate them. Real RAG-quality separation needs harder/adversarial questions + LLM-as-judge (Benchmark Index scope). Extraction F1 (clean Synthea gold) was the trustworthy signal in the dev sweep.
- **Aggregate scores hide field-level artifacts — inspect per-field + spot-check pred-vs-gold.** Scaled extraction first read 86.5%, masking `provider_name` at 0.2%: the invoice rendered the provider as an unlabeled `"Name · Specialty"` header and the 7B returned the specialty alone ~⅔ of the time (not a numeric-suffix or scorer issue — we chased both before just *printing pred vs gold*). A labeled field → 100%, overall → 99%. The cheap **dev-tier validation caught it before the paid sweep** — always validate the pipeline on cheap hardware first.

---

## Internal toolchain / dev-env — `[INTERNAL]` (do **not** publish)

### IN-1 · Terraform won't `brew install`; use OpenTofu
`brew install hashicorp/tap/terraform` fails — *"Your Xcode (16.2) … is too outdated"* — on an arm64 Mac running Intel Homebrew under Rosetta (the tap formula builds from source). **Fix:** `brew install opentofu` (`tofu`), a drop-in that validates identical HCL from a pre-built bottle. Under Rosetta the AWS provider plugin occasionally times out on the first `tofu validate` — just retry. The Makefile auto-detects `terraform` else `tofu`.

### IN-2 · A local Postgres on :5432 hijacks the port-forward
`psycopg2 … password authentication failed for user "rag"` when connecting through `kubectl port-forward 5432:5432`. The port-forward log shows `bind: address already in use` — a local Postgres owns 5432, so the client hit the *local* DB, not the cluster's. **Fix:** forward to a non-colliding local port (we use `55432`).

### IN-3 · Inline-Python scripting traps
Two recurring bugs writing quick verifiers: (a) piping data into `python3 <<'HEREDOC'` fails because the heredoc takes stdin, so `json.load(sys.stdin)` gets nothing — pass the program via `python3 -c` so stdin stays free for the piped data; (b) f-strings with escaped quotes inside a shell-quoted `-c` throw `SyntaxError` — use `%`-formatting in inline `-c`. Pure scripting hygiene, not architecture.
