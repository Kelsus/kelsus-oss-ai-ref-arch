# Model sweep — cost/latency (same instance, same workload)

| model | peak tok/s | TTFT p99 @64 (ms) | $/M out tok (peak) |
|---|---:|---:|---:|
| microsoft/Phi-3.5-mini-instruct | 3494.1 | 117.5 | 0.1479 |
| Qwen/Qwen2.5-VL-7B-Instruct | 2389.1 | 152.7 | 0.2164 |
| Qwen/Qwen2.5-7B-Instruct | 2320.3 | 144.1 | 0.2228 |

_No single composite score — pick per your workload's latency vs throughput vs cost priorities (and, separately, the quality numbers from the RAG/extraction runs)._
