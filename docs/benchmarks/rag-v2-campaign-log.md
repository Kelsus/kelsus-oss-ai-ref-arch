# RAG re-collection campaign log (metric v2, gold v2 n=226)
| model | s3 result key | status | notes |
|---|---|---|---|
| kimi-k2-instruct | results/quality/20260702T015732Z.json | LANDED 226/226 ctx, 0 err | take 2 (AMI-drift killed take 1); p5e spot |
| qwen3-vl-235b | results/quality/20260702T023838Z.json | LANDED 226/226 ctx | 10.5m ready, 30m collect |
| deepseek-v3.1 | results/quality/20260702T033228Z.json | LANDED 226/226 ctx | 20m ready, 32m collect |
| deepseek-v3.2 | results/quality/20260702T041539Z.json | LANDED 226/226 ctx | 10.5m ready, 32m collect |
| glm-4.7 | results/quality/20260702T045702Z.json | LANDED 226/226 ctx | 8m ready, 32m collect |
| kimi-k2.5 | results/quality/20260702T054355Z.json | LANDED 226/226 ctx | landed unattended during SSO gap |
| ornith | results/quality/20260702T154225Z.json | LANDED 226/226 ctx | 107m ready (794GB), 35m collect |
| glm-5.2 | results/quality/20260702T162856Z.json | LANDED 226/226 ctx | 10.5m ready, 34m collect |
| deepseek-v4-pro | results/quality/20260702T172111Z.json | LANDED 226/226 ctx | 16m ready (!), 35m collect |
| nemotron | results/quality/20260702T180924Z.json | LANDED 226/226 ctx | 14.5m ready, 32m collect |
| llama4-scout | results/quality/20260702T190307Z.json | LANDED 226/226 ctx | 22.5m ready, 29m collect |
| qwen3-235b | results/quality/20260702T194114Z.json | LANDED 226/226 ctx | 8m ready, 29m collect (rendered manifest, pinned v0.23.0) |
| qwen2.5-vl-72b | results/quality/20260702T202525Z.json | LANDED 226/226 ctx | 6.5m ready, 20m collect (g6e.24xl OD) |
| glm-4.5-air | results/quality/20260702T230953Z.json | LANDED 226/226 ctx | FINAL self-host serve |
| kimi-k2.5-bedrock | managed-kimi-k2.5-bedrock-20260703T050858Z.json | LANDED 226/226 ctx (retry) | sweep FAILED-verdict bug + PROVIDER restore race, fixed live |
