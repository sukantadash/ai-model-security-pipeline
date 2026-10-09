# Test zone — verified model serving after pipeline pass

All serving manifests live in this directory (no subfolders).

- **Phase 2 (overlay `04-zones`):** `namespace.yaml` via `overlays/04-zones/model-test/`
- **Overlay `16-test-serving`:** network policies, RBAC, `LLMInferenceServiceConfig`
- **Verified `LLMInferenceService`:** applied by `publish-artifact` (not kustomize)

## ModelCar + placeholder image

Committed example: [`qwen3-8b-fp8-verified.yaml`](qwen3-8b-fp8-verified.yaml) with `spec.model.uri: oci://PLACEHOLDER`.

PipelineRun params:

- `model-id` / `modelcar-image` — must match the model-fetch Job
- `serving-yaml` — path to this file (or another model’s YAML)

On auto-pass / review, `publish-artifact`:

1. Retags ModelCar `<model-id>-unverified` → `<model-id>-verified-<score>-<VERSION>`
2. Registers Model Registry with `oci://…`
3. Replaces **only** the placeholder URI in `serving-yaml` and `oc apply`s it in `model-test`

No `.yaml.template` and no rewriting of names or ODH connection annotations.

## NeMo Guardrails

On auto-pass and review, `nemo-guardrails-test` deploys `NemoGuardrails/nemo-guardrails` (auth on) in front of the verified model. Prerequisites: overlay 04-zones applies `instances/model-test-ns/nemo-guardrails-serviceaccount.yaml` (NeMo SA + token Secret) and the pipeline's NeMo rights in `pipeline-apply-rbac.yaml`. Overlay 04-zones also applies `instances/model-test-ns/serving-rbac.yaml` (`test-user` + `nemo-guardrails-user` Role for the smoke tests) and `networkpolicy-nemo-guardrails-apiserver.yaml` (auth proxy → API server). See [docs/nemo-guardrails.md](../../docs/nemo-guardrails.md#verifying-in-model-test-guide-ch-32-verification).

```bash
GUARDRAILS_ROUTE=https://$(oc get routes/nemo-guardrails -n model-test -o jsonpath='{.status.ingress[0].host}')
curl -sk -X POST "${GUARDRAILS_ROUTE}/v1/chat/completions" \
  -H "Content-Type: application/json" -H "Authorization: Bearer $(oc create token test-user -n model-test)" \
  -d '{"model":"redhatai-qwen3-8b-fp8-dynamic","messages":[{"role":"user","content":"I yearn for violence"}]}'
```

## Smoke test

```bash
GATEWAY_HOST=$(oc get gateway openshift-ai-inference -n openshift-ingress \
  -o jsonpath='{.spec.listeners[0].hostname}')
GATEWAY_URL="https://${GATEWAY_HOST}/model-test/qwen3-8b-fp8"
TOKEN="$(oc create token test-user -n model-test)"

curl -sS "${GATEWAY_URL}/v1/models" -H "Authorization: Bearer ${TOKEN}" | jq .
```

Ensure Quay pull secrets exist in `model-test` (gitops-scripts Phase 2) so the verified ModelCar can be pulled.
