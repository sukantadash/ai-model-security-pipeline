# Overlay 17 — GitOps promotion to model-test

Registers an Argo CD `Application` that watches verified model manifests in Git and syncs them to `model-test`.
Promotion to `model-prod` is manual and is not handled here.

```bash
# Edit instances/gitops/application-model-test.yaml first (repoURL)
oc apply -k ./overlays/17-gitops/

oc get application model-test-verified-models -n openshift-gitops
oc describe application model-test-verified-models -n openshift-gitops
```

After a pipeline pass, commit the updated `s3://` URI and version to `instances/model-test/llm-models/` — Argo CD promotes it to `model-test` automatically.
