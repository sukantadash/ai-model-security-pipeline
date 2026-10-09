# Storage and registry

**MinIO overlay:** [`overlays/05-storage`](../overlays/05-storage)  
**Buckets:** created by [`instances/minio/bucket-init-job.yaml`](../instances/minio/bucket-init-job.yaml)

![Storage flow](diagrams/storage-flow.svg)

*Weights are ModelCar OCI images. Scan JSON stays in MinIO. Version is the last five characters of the PipelineRun name.*

## What lives where

| Asset | Store | Namespace | Notes |
|-------|-------|-----------|-------|
| Scanner images | Internal registry / Quay | `build-image` | Not model weights |
| Untrusted weights | Quay `…/ai-model-security-pipeline:<model-id>-unverified` | OCI | Built by `model-fetch` Job |
| Eval workspace | PVC `eval-workspace` | `model-eval` | `/models` extracted from unverified tag |
| Scan JSON | MinIO `models-eval/<model-id>/<version>/scan-result/` | S3 | Per-subtask + merges + `score.json` |
| Verified weights | Quay `…:<model-id>-verified-<score>-<version>` | OCI | Publish retag on auto-pass or review |
| Attestations | MinIO `attestations/` | S3 | Tekton Chains target |
| Serving pointer | RHOAI Model Registry | `rhoai-model-registries` | `storage_uri` = `oci://…` |
| Run history | MLflow (experiment `ai-model-security-pipeline`, workspace `model-eval`) | server in `redhat-ods-applications` | Metadata: SQLite on PVC; artifacts: MinIO bucket `mlflow`. One run per PipelineRun |

Buckets `models-ingress` / `models-verified` may still exist from older installs; the pipeline no longer writes weights there.

## Version key

PipelineRun `model-security-9x57m` → version `9x57m`. Score 87 → tag `…-verified-87-9x57m`.

```text
s3://models-eval/<model-id>/9x57m/scan-result/*.json
oci://quay.io/sudash/ai-model-security-pipeline:<model-id>-verified-87-9x57m
```

## Object names in `scan-result/`

| Writer | Object |
|--------|--------|
| Static subtasks | `static-malware.json`, `static-vulnerabilities.json`, `static-license-compliance.json` |
| Static merge | `static-scan.json` |
| Dynamic subtasks | `dynamic-isolated-runtime.json`, `dynamic-behavior.json`, `dynamic-abnormal-resources.json`, `dynamic-basic-inference.json` |
| Dynamic merge | `dynamic-scan.json` |
| Capability subtasks | `capability-quality.json`, `capability-performance-cost.json`, `capability-stability.json`, `capability-anomaly-bias.json` |
| Capability merge | `capability.json` |
| Adversarial subtasks | `adversarial-prompt-injection.json`, `adversarial-jailbreak-guardrail-bypass.json`, `adversarial-harmful-content-bias.json` |
| Adversarial merge | `adversarial-test.json` |
| NeMo Guardrails subtask (live) | `nemo-guardrails-summary.json` — probe counts (attacks blocked, false positives, errors, thinking replies); read by MLflow logging and `tools/compare_models.py`, ignored by score-gate |
| Score gate | `score.json` |
| Publish | `publish.json` |
| Archive (`finally`) | `manifest.json` (then the same files are logged to MLflow as artifacts) |

## Hugging Face → ModelCar

```text
hf://RedHatAI/Qwen3-8B-FP8-dynamic
  -> model-fetch Job (instances/model-ingress-fetch; Containerfile via model-ingress ConfigMap)
  -> quay.io/sudash/ai-model-security-pipeline:redhatai-qwen3-8b-fp8-dynamic-unverified
  -> PipelineRun (model-id + modelcar-image + serving-yaml)
  -> fetch-artifact: oc image extract /models onto eval PVC
  -> serve-llm-start: oci://…:<model-id>-unverified (placeholder replace)
  -> publish: retag …:<model-id>-verified-<score>-<version> + apply serving-yaml
```

Knobs for any model: Job `HF_REPO` / `MODEL_ID`, PipelineRun `model-id` / `serving-yaml` (shared `modelcar-image` repo).

## Model Registry and serving

On auto-pass or review, `publish-artifact`:

1. Refuses unless `score.json` routing is `auto-pass` or `review`.
2. Retags ModelCar `<model-id>-unverified` → `<model-id>-verified-<score>-<version>`.
3. Registers Model Registry artifact with `oci://` URI.
4. Clones `serving-yaml`, replaces `spec.model.uri` placeholder only, `oc apply` in `model-test`.
