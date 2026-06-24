# Benchmark + load harness

Emits the measured numbers that backfill [`docs/architecture.md`](../docs/architecture.md)
and feed the public **Kelsus Enterprise OSS LLM Index**. The layout deliberately
mirrors the Index harness (`kelsus/oss-llm-index`) so one harness serves both.

```
bench/
  workloads/   one module per workload class
  configs/     one yaml per model per run (instance type, quant, vLLM flags)
  judges/      LLM-as-judge prompts + scoring rubrics (pre-registered)
  runner/      orchestration; runs configs, writes raw CSV
  reports/     generates published artifacts; runs/ holds raw CSV (gitignored)
```

## Workloads (v1 = four; agentic deferred to v2, per the Index methodology)
| Workload | Metric | Driven by |
|---|---|---|
| RAG quality | LLM-judge + passage-grounding F1 | App 2 |
| Function calling | task completion, call precision, arg F1 | App 1 |
| Long context | accuracy vs length (32K→256K) | App 2 |
| Cost & latency | TTFT, p95, tok/s/replica, $/M-token @ 30/60/90% util | both |
| Agentic *(v2)* | end-to-end completion, tool-call efficiency | App 1 |

## Run
```bash
make smoke                 # one request end-to-end (sanity)
make bench MODEL=<id>      # full run -> bench/reports/runs/<ts>/
```

Properties enforced: temperature 0 by default, fixed retrieval pipeline across
models, pre-registered judge prompts, identical concurrency profiles, two
independent runs per model to bound variance.
