# Overlay 16 — Test serving

Applies verified `LLMInferenceService` manifests to `model-test`.
Promotion to `model-prod` is a later manual process.

**Before applying:**

1. Complete Phases 0–10 and a successful pipeline run (Phase 10 manual test).
2. Apply RHOAI inference prerequisites (Overlays 11–15).
3. Patch the inference gateway to allow routes from `model-test`.
4. Edit `instances/model-test/llm-models/qwen3-8b-fp8-verified.yaml` — set `model-version` and `s3://` URI from publish (version is the last five characters of the PipelineRun name).

```bash
oc apply -k ./overlays/16-test-serving/
oc wait --for=condition=Ready llminferenceservice/qwen3-8b-fp8 -n model-test --timeout=600s
```
