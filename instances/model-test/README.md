# Test zone — verified model serving after pipeline pass (registry-driven).
# Promotion from model-test to model-prod is a later manual process.

Deploy **after** a model passes `model-security-pipeline` in `model-eval`.

## Prerequisites (overlays 11–15)

Apply the RHOAI inference platform before verified model serving (see `script.sh` Phases 11–14).

## After publish-artifact

1. Read `publish.json` from `s3://models-eval/<model-id>/<version>/scan-result/` or task logs.
2. Update `llm-models/qwen3-8b-fp8-verified.yaml` (or let `publish-artifact` patch from git):
   - `security.platform/model-version` (last five characters of the PipelineRun name, e.g. `9x57m`)
   - `spec.model.uri` → `model-registry://redhatai-qwen3-8b-fp8-dynamic/<version>`
   Weights remain at `s3://models-verified/...`; the storage-initializer resolves them via Model Registry metadata.
   Scan reports for that version: `s3://models-eval/redhatai-qwen3-8b-fp8-dynamic/<version>/scan-result/`
3. Apply overlay 16 or commit for GitOps (overlay 17) into **model-test**.

## Smoke test

```bash
GATEWAY_HOST=$(oc get gateway openshift-ai-inference -n openshift-ingress \
  -o jsonpath='{.spec.listeners[0].hostname}')
GATEWAY_URL="https://${GATEWAY_HOST}/model-test/qwen3-8b-fp8"
TOKEN="$(oc create token test-user -n model-test)"

curl -sS "${GATEWAY_URL}/v1/models" -H "Authorization: Bearer ${TOKEN}" | jq .
```

Ensure `minio-s3` secret exists in `model-test` so serving can read verified weights from MinIO.
