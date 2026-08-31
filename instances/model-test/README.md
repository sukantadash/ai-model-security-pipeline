# Test zone — verified model serving after pipeline pass (registry-aligned).
# Promotion from model-test to model-prod is a later manual process.

All serving manifests live in this directory (no subfolders).

- **Phase 2 (overlay `04-zones`):** `namespace.yaml` via `overlays/04-zones/model-test/` (kustomize requires it under the overlay tree; keep both namespace copies in sync).
- **Phase 15 (overlay `16-test-serving`):** network policies, RBAC, `LLMInferenceServiceConfig`, ODH connection secret, verified `LLMInferenceService`.

Deploy **after** a model passes `model-security-pipeline` in `model-eval`.

## Alignment with Model Registry deploy

The RHOAI dashboard deploys from Model Registry into `minio-system` with:

- `LLMInferenceServiceConfig` + `baseRefs` (vLLM CUDA runtime)
- `opendatahub.io/connection-path` / `opendatahub.io/connections` → per-version S3 secret
- `spec.model.uri` → `s3://models-verified/<registered-model>/<version>` (no trailing slash)
- `spec.model.name` → registered model id (not Hugging Face name)
- Preset router (`gateway` + `route` only — no custom scheduler block)

`model-test` mirrors that pattern and adds `gpu-profile`, security annotations, and gateway name `qwen3-8b-fp8`.

## Prerequisites (overlays 11–15)

Apply the RHOAI inference platform before verified model serving (see `script.sh` Phases 11–14).

## After publish-artifact

1. Read `publish.json` from `s3://models-eval/<model-id>/<version>/scan-result/` or task logs.
2. Update manifests (or let `publish-artifact` patch from git) — version token is `PLACEHOLDER` in Git:
   - `MODEL_CONN_NAME` → `redhatai-qwen3-8b-fp8-dynamic-<version>` (`opendatahub.io/connections`)
   - `opendatahub.io/connection-path` → `<registered-model>/<version>`
   - `spec.model.uri` → `s3://models-verified/<registered-model>/<version>`
3. Phase 15 in `script.sh` sets `MODEL_CONN_VERSION` (default `d4xs2`) and applies both templates via `sed`, or apply overlay 16 for RBAC/NP only:

```bash
export MODEL_CONN_VERSION=d4xs2   # last five chars of PipelineRun name
# script.sh Phase 15 block, or manually:
sed "s/PLACEHOLDER/${MODEL_CONN_VERSION}/g" instances/model-test/qwen3-8b-fp8-verified.yaml | oc apply -n model-test -f -
oc apply -k ./overlays/16-test-serving/ -n model-test
```

Requires `minio-s3-secret.yaml` from Phase 4 for connection secret credentials.

## Smoke test

```bash
GATEWAY_HOST=$(oc get gateway openshift-ai-inference -n openshift-ingress \
  -o jsonpath='{.spec.listeners[0].hostname}')
GATEWAY_URL="https://${GATEWAY_HOST}/model-test/qwen3-8b-fp8"
TOKEN="$(oc create token test-user -n model-test)"

curl -sS "${GATEWAY_URL}/v1/models" -H "Authorization: Bearer ${TOKEN}" | jq .
```

Ensure Phase 4 created `minio-s3-secret.yaml` and applied `minio-s3` in `model-test`. Phase 15 in `script.sh` applies `model-connection-secret.yaml.template` and `qwen3-8b-fp8-verified.yaml` with `MODEL_CONN_VERSION` (substitutes `PLACEHOLDER`). `publish-artifact` does the same on each promote.
