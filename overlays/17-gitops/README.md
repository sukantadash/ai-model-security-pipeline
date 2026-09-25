# Overlay 17 — GitOps App-of-Apps

Applies the root Argo CD Application `ai-model-security-platform`, which syncs all child Applications under `instances/gitops/apps/` (script.sh overlays 00–15 + model-ingress + model-test promotion).

OpenShift GitOps must already be installed. Follow step-by-step phases in `gitops-scripts.sh` (copy/paste like `script.sh`):

```bash
# Phase 0 from gitops-scripts.sh
oc apply -k ./overlays/17-gitops/

oc get application ai-model-security-platform -n openshift-gitops
oc get applications -n openshift-gitops -l app.kubernetes.io/part-of=ai-model-security-pipeline
```

`overlays/16-test-serving` is **not** an Argo app (gitignored generated files); apply it in `gitops-scripts.sh` Phase 5 after secrets/builds.

After a pipeline pass, commit the updated verified LLMInferenceService under `instances/model-test/` — the `model-test-verified-models` child Application promotes it to `model-test`.
