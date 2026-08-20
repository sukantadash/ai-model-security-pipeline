# Overlay 16 — Production serving

Applies verified `LLMInferenceService` manifests to `model-prod`.

**Before applying:**

1. Complete Phases 0–10 and a successful pipeline run (Phase 10 manual test).
2. Apply RHOAI inference prerequisites (Overlays 11–15).
3. Patch the inference gateway to allow routes from `model-prod`.
4. Edit `instances/model-prod/llm-models/qwen-verified.yaml` — replace `PLACEHOLDER` org and `@sha256:...` digest.

```bash
oc apply -k ./overlays/16-production-serving/
oc wait --for=condition=Ready llminferenceservice/qwen -n model-prod --timeout=600s
```
