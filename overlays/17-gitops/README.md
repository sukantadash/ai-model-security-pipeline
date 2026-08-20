# Overlay 17 — GitOps promotion

Registers an Argo CD `Application` that watches verified model manifests in Git.

```bash
# Edit instances/gitops/application-model-prod.yaml first (repoURL)
oc apply -k ./overlays/17-gitops/

oc get application model-prod-verified-models -n openshift-gitops
oc describe application model-prod-verified-models -n openshift-gitops
```

After a pipeline pass, commit the updated `oci://` URI to `instances/model-prod/llm-models/` — Argo CD promotes it to `model-prod` automatically.
