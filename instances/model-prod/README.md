# Production zone — verified model serving (registry-driven)

Deploy **after** a model passes `model-security-pipeline` in `model-eval`.

## Prerequisites (overlays 11–15)

Apply the RHOAI inference platform before verified model serving (see `script.sh` Phases 11–14).

## After publish-artifact

1. Read `publish.json` from the PipelineRun results workspace or task logs.
2. Update `llm-models/qwen3-8b-fp8-verified.yaml`:
   - `security.platform/model-version`
   - `spec.model.uri` → `s3://models-verified/redhatai-qwen3-8b-fp8-dynamic/<version>/`
3. Apply overlay 16 or commit for GitOps (overlay 17).

## Smoke test

```bash
GATEWAY_HOST=$(oc get gateway openshift-ai-inference -n openshift-ingress \
  -o jsonpath='{.spec.listeners[0].hostname}')
GATEWAY_URL="https://${GATEWAY_HOST}/model-prod/qwen3-8b-fp8"
TOKEN="$(oc create token test-user -n model-prod)"

curl -sS "${GATEWAY_URL}/v1/models" -H "Authorization: Bearer ${TOKEN}" | jq .
```

Ensure `minio-s3` secret exists in `model-prod` so serving can read verified weights from MinIO.
