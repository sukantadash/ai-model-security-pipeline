# Overlay 16 — Test serving

Applies `instances/model-test` RBAC, network policies, and `LLMInferenceServiceConfig` to `model-test`.

The verified `LLMInferenceService` and ODH connection secret use `PLACEHOLDER` in Git — apply via `script.sh` Phase 15 (or `publish-artifact` on pipeline pass).

**Before applying:**

1. Complete Phases 0–10 and a successful pipeline run.
2. Apply RHOAI inference prerequisites (Overlays 11–15).
3. Phase 4: `minio-s3-secret.yaml` in `model-test`.
4. Set `MODEL_CONN_VERSION` to the promoted version (last five characters of the PipelineRun name, e.g. `d4xs2`).

```bash
export MODEL_CONN_VERSION=d4xs2
# script.sh Phase 15 block, or:
sed -e "s/PLACEHOLDER/${MODEL_CONN_VERSION}/g" \
    -e "s/CHANGE_ME_MINIO_ROOT_USER/.../" \
    -e "s/CHANGE_ME_MINIO_ROOT_PASSWORD/.../" \
  instances/model-test/model-connection-secret.yaml.template | oc apply -n model-test -f -
sed "s/PLACEHOLDER/${MODEL_CONN_VERSION}/g" \
  instances/model-test/qwen3-8b-fp8-verified.yaml | oc apply -n model-test -f -
oc apply -k ./overlays/16-test-serving/ -n model-test
oc wait --for=condition=Ready llminferenceservice/qwen3-8b-fp8 -n model-test --timeout=600s
```
