# Pipeline Subtasks & Tooling Breakdown


| Stage               | Subtask                      | Installed Tools / Executables                   | Key Activities & Logic                                                                           |
| ------------------- | ---------------------------- | ----------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| 0. Fetch            | `fetch-artifact`             | MinIO Client (`mc`)                             | Syncs raw model weights from ingress S3 onto the evaluation PVC.                                 |
| 0.1 Sandbox         | `serve-llm-start` / `stop`   | OpenShift CLI (`oc`), `mc`                      | Clones git repo, patches and applies `LLMInferenceService` CRD, exports endpoint.                |
| 1. Static Scan      | `malware`                    | Magika, ModelAudit, Fickling, ModelScan, ClamAV | Classifies binaries, scans code/pickles for unsafe execution calls, checks AV databases.         |
|                     | `vulnerabilities`            | Syft, Grype                                     | Generates model directory SBOM (excluding weight files) and matches against frozen Grype CVE DB. |
|                     | `license-compliance`         | Syft, `static_scan.py` heuristics               | Reads LICENSE files, configs, and SBOM to check against ALLOW / COPYLEFT / DENY policies.        |
| 2. Dynamic Scan     | `isolated-runtime`           | Cluster RuntimeClass & NetworkPolicy inspection | Checks for Kata/VM isolation and ensures no public egress (`0.0.0.0/0:443`) or K8s API access.   |
|                     | `behavior`                   | `falco-alerts.json` (Fixture parser)            | Parses runtime behavior alerts (live Falco/Tetragon integration planned).                        |
|                     | `abnormal-resources`         | `kepler-samples.json` (Fixture parser)          | Evaluates CPU, RSS memory, GPU power ceiling overages, and OOM events.                           |
|                     | `basic-inference`            | UBI Python (`vllm_client.py`)                   | Tests `/health`, `/v1/models`, and sends a ping request to `/v1/chat/completions`.               |
| 3. Capability Eval  | `quality`                    | `vllm_client.py`                                | Runs short benchmark probes (MMLU, GSM8K, HumanEval) via `/v1/chat/completions`.                 |
|                     | `performance-cost`           | `vllm_client.py`                                | Measures P99 latency, tokens/sec, and calculates estimated USD cost per GPU hour.                |
|                     | `stability-check`            | `vllm_client.py`                                | Measures jitter, P99/P50 latency ratios, and request timeout rates across repeated calls.        |
|                     | `anomaly-bias-detection`     | `vllm_client.py`                                | Monitors empty/repetitive completion rates and evaluates quality regression against baseline.    |
| 4. Adversarial Test | `prompt-injection`           | `vllm_client.py`                                | Sends delimiter breakouts / instruction override probes to detect system prompt or secret leaks. |
|                     | `jailbreak-guardrail-bypass` | `vllm_client.py`                                | Sends DAN / developer-mode prompts; detects bypasses via affirmative compliance keywords.        |
|                     | `harmful-content-bias`       | `vllm_client.py`                                | Probes for toxic, violent, or illegal content generation using keyword detection rules.          |
| 5. Gate & Post-Scan | `score-gate`                 | `aggregate-results.py`                          | Calculates composite score Stotal = 0.40·Sstatic + 0.35·Scapability + 0.25·Sredteam.             |
|                     | `publish-artifact`           | `mc`, `curl`, `jq`                              | Promotes passed models to `s3://models-verified/` and registers them with RHOAI Registry.        |
|                     | `archive-results`            | `mc`                                            | Compiles evaluation findings and writes `manifest.json` back to MinIO storage.                   |


