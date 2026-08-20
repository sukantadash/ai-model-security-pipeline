# GitOps — verified model promotion

Argo CD watches `instances/model-prod/llm-models/` and syncs changes to the `model-prod` namespace.

## Promotion workflow

1. Model passes `model-security-pipeline`; `publish-artifact` emits a digest-pinned `oci://` URI.
2. Update `instances/model-prod/llm-models/qwen-verified.yaml` with the new URI (commit to Git).
3. Argo CD syncs automatically (overlay 17) or run `oc apply -k ./overlays/16-production-serving/` manually.

## Setup

1. Push this repo to a Git remote Argo CD can reach.
2. Edit `application-model-prod.yaml` — set `spec.source.repoURL` and `targetRevision`.
3. If using a private repo, create a repository credential secret in `openshift-gitops` (see template in this file's history).
4. Apply overlay 17:

```bash
oc apply -k ./overlays/17-gitops/
oc get application model-prod-verified-models -n openshift-gitops
```

## Rollback

Revert the Git commit that updated `spec.model.uri`. Argo CD self-heals to the previous manifest.
