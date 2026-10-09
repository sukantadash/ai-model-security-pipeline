# Pipeline

**Pipeline:** `model-security-pipeline` in `model-eval`  
**Source:** [`instances/tekton-pipeline/pipeline.yaml`](../instances/tekton-pipeline/pipeline.yaml)

![Tekton DAG](diagrams/pipeline-dag.svg)

*Parallel subtasks merge before the next stage. `publish-artifact` is conditional. `archive-results` is `finally`.*

## Params and workspaces

| Name | Kind | Role |
|------|------|------|
| `model-id` | param | Model id (must match fetch Job `MODEL_ID`) |
| `modelcar-image` | param | Shared Quay repo (tags = `<model-id>-unverified` / `-verified-<score>-<version>`) |
| `model-path` | param | Default `/workspace/models` |
| `model-registry-namespace` | param | Default `rhoai-model-registries` |
| `git-url` | param | Git repo with serving YAML |
| `model-sandbox-path` | param | File path to sandbox LLMIS YAML (placeholder image) |
| `serving-yaml` | param | File path to verified LLMIS YAML (placeholder image only) |
| `nemo-guardrails-enabled` | param | Default `'true'`. NeMo Guardrails in sandbox (scored) and in front of the verified model |
| `mlflow-tracking-uri` | param | MLflow tracking server; `archive-results` logs one MLflow run per PipelineRun. Empty = no MLflow (deploy.sh fills it in) |
| `test-guardrails-name` | param | Default `nemo-guardrails`. CR / Service / Route name in `model-test` |
| `shared-data` | workspace | PVC `eval-workspace` — **weights only** (extracted from `<model-id>-unverified`) |
| `results` | workspace | Pod-local `emptyDir` for JSON before S3 upload; not shared across TaskRuns |

Capability-eval and adversarial-test TaskRuns are CPU HTTP clients. GPU is requested by the **sandbox** `LLMInferenceService` in `model-sandbox`.

## DAG (as coded)

```text
fetch-artifact
  -> malware | vulnerabilities | license-compliance  -> static-scan (merge)
  -> serve-llm-start
  -> isolated-runtime | behavior | abnormal-resources | basic-inference  -> dynamic-scan (merge)
  -> quality | performance-cost | stability-check | anomaly-bias-detection  -> capability-eval (merge)
     nemo-guardrails-start   (parallel with capability; NemoGuardrails CR in model-sandbox)
  -> prompt-injection | jailbreak-guardrail-bypass | harmful-content-bias | nemo-guardrails  -> adversarial-test (merge)
  -> score-gate
  -> publish-artifact   when routing is auto-pass or review
  -> nemo-guardrails-test   when routing is auto-pass or review and nemo-guardrails-enabled=true

finally: nemo-guardrails-stop, serve-llm-stop, archive-results
```

Merge Tasks always succeed. They concat per-subtask JSON into `static-scan.json`, `dynamic-scan.json`, `capability.json`, `adversarial-test.json`.

## Stages

### Fetch

| Pipeline task | Tekton Task | Image | Output |
|---------------|-------------|-------|--------|
| `fetch-artifact` | `fetch-artifact` | `openshift/cli` | Extract `/models` from ModelCar `<model-id>-unverified` onto eval PVC |

### Static security scanning (stage 1)

| Pipeline task | Tekton Task | Tools (installed) | Scan object |
|---------------|-------------|-------------------|-------------|
| `malware` | `static-scan-malware` | Magika, ModelAudit, Fickling, ModelScan, ClamAV | `static-malware.json` |
| `vulnerabilities` | `static-scan-vulnerabilities` | Syft + Grype | `static-vulnerabilities.json` |
| `license-compliance` | `static-scan-license-compliance` | LICENSE / config.json / Syft + `policy.json` | `static-license-compliance.json` |
| `static-scan` | `static-scan-merge` | concat | `static-scan.json` |

Immediate-fail (Task stops the pipeline): ModelAudit critical matching exec/eval/os.system/pickle needles; ClamAV FOUND; required tool missing / empty SBOM. License deny-list and CVEs continue so the composite can be scored.

### Dynamic scan (stage 2) — hard gate

Not part of `S_total`. Score-gate rejects on `critical` or `high` in `dynamic-scan.json`.

| Pipeline task | Tekton Task | Intent | Today |
|---------------|-------------|--------|-------|
| `isolated-runtime` | `dynamic-scan-isolated-runtime` | Sandbox pod runtimeClass + NetworkPolicy | `oc` inspect + Python |
| `behavior` | `dynamic-scan-behavior` | Falco fixture or sandbox pod events | Fixture JSON / events |
| `abnormal-resources` | `dynamic-scan-abnormal-resources` | Kepler fixture or sandbox pod OOM | Fixture JSON / pod status |
| `basic-inference` | `dynamic-scan-basic-inference` | HTTP ping to sandbox `LLMInferenceService` | Live in pipeline |
| `dynamic-scan` | `dynamic-scan-merge` | concat | `dynamic-scan.json` |

`RUNTIME_CLASS=kata` is unused as proof. Live isolated-runtime inspects the sandbox serving pod.

### Capability evaluation (stage 3) — 35% of `S_total`

HTTP clients against `model-endpoint`. Image is UBI Python (`vllm_client.py`). Full lm-eval / TruLens are not installed. Unit fixtures still work without an endpoint.

| Pipeline task | Output |
|---------------|--------|
| `quality` | `capability-quality.json` (live prompts or fixture thresholds) |
| `performance-cost` | `capability-performance-cost.json` (p99, tokens/sec, cost) |
| `stability-check` | `capability-stability.json` (p99/p50, jitter, timeouts) |
| `anomaly-bias-detection` | `capability-anomaly-bias.json` (regression, bias, anomaly rate) |
| `capability-eval` | `capability.json` |

### Adversarial test (stage 4) — 25% of `S_total`

HTTP clients against `model-endpoint`. Garak / PyRIT / Promptfoo / LLM Guard are **not** installed. `nemo-guardrails` targets the NeMo Guardrails endpoint from `nemo-guardrails-start` instead ([NeMo Guardrails](nemo-guardrails.md)).

| Pipeline task | Output |
|---------------|--------|
| `prompt-injection` | `adversarial-prompt-injection.json` |
| `jailbreak-guardrail-bypass` | `adversarial-jailbreak-guardrail-bypass.json` |
| `harmful-content-bias` | `adversarial-harmful-content-bias.json` |
| `nemo-guardrails` | `adversarial-nemo-guardrails.json` (block rate, false-positive rate through NeMo) |
| `adversarial-test` | `adversarial-test.json` |

### Gate, publish, archive

| Pipeline task | When | Effect |
|---------------|------|--------|
| `serve-llm-start` | After static-scan; all later tasks wait | Replace placeholder with `oci://…:<model-id>-unverified`; apply sandbox YAML |
| `score-gate` | After adversarial merge | Writes `score.json`; Task fails only on `routing=reject` |
| `publish-artifact` | `when: routing in auto-pass, review` | Retag `<model-id>-verified-<score>-VERSION`; register MR; apply `serving-yaml` (URI only) |
| `nemo-guardrails-start` | After dynamic-scan | `nemo-guardrails-deploy` in `model-sandbox` (auth off); result `endpoint-url` |
| `nemo-guardrails-test` | After publish, same `when` + `nemo-guardrails-enabled` | `nemo-guardrails-deploy` in `model-test` (auth on, Route `nemo-guardrails`) |
| `nemo-guardrails-stop` | `finally` | Deletes the sandbox `NemoGuardrails` CR + ConfigMaps |
| `serve-llm-stop` | `finally` | Deletes the sandbox `LLMInferenceService` (namespace stays) |
| `archive-results` | `finally` (always) | `manifest.json` in the same scan-result prefix; step `log-mlflow` logs the run to MLflow (`builds/publish/scripts/log_mlflow.py`; never fails the task) |

## Scanner images

Built in namespace `build-image` (no zone NetworkPolicy). Pulled by Tasks from the in-cluster registry.

`image-registry.openshift-image-registry.svc:5000/build-image/ai-security-<name>:latest`

| BuildConfig | Used by |
|-------------|---------|
| `ai-security-model-fetch` | fetch-artifact, ingress HF Job |
| `ai-security-static-scan` | static subtasks |
| `ai-security-dynamic-test` | dynamic subtasks |
| `ai-security-capability-eval` | capability subtasks |
| `ai-security-adversarial-test` | adversarial subtasks (including `nemo-guardrails`) |
| `openshift/cli` (in-cluster) | serve-llm, nemo-guardrails-deploy / -delete |
| TrustyAI NeMo image (operator-managed) | `NemoGuardrails` server pods — not built here |
| `ai-security-score-gate` | score-gate |
| `ai-security-publish` | publish-artifact, archive-results (includes the MLflow client `mlflow-skinny[kubernetes]`) |

See [`builds/README.md`](../builds/README.md).
