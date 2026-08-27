# GitOps — verified model promotion to model-test

Argo CD watches `instances/model-test/llm-models/` and syncs changes to the `model-test` namespace.
Promotion from `model-test` to `model-prod` is a later manual process.

## Promotion workflow

1. Model passes `model-security-pipeline`; `publish-artifact` emits `s3://models-verified/<model-id>/<version>/` (version = last five characters of the PipelineRun name).
2. Scan reports for that version: `s3://models-eval/<model-id>/<version>/scan-result/`.
3. Update `instances/model-test/llm-models/qwen3-8b-fp8-verified.yaml` with the new URI and version (commit to Git).
4. Argo CD syncs automatically (overlay 17) or run `oc apply -k ./overlays/16-test-serving/` manually.

## Setup

1. Push this repo to a Git remote Argo CD can reach.
2. Edit `application-model-test.yaml` — set `spec.source.repoURL` and `targetRevision`.
3. If using a private repo, create a repository credential secret in `openshift-gitops`.
4. Apply overlay 17:

```bash
oc apply -k ./overlays/17-gitops/
oc get application model-test-verified-models -n openshift-gitops
```

## Rollback

Revert the Git commit that updated `spec.model.uri`. Argo CD self-heals to the previous manifest.
