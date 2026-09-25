# GitOps — App-of-Apps for platform + verified model promotion

OpenShift GitOps (Argo CD) deploys the declarative overlays from `script.sh` via an App-of-Apps root Application. Promotion from `model-test` to `model-prod` remains a later manual process.

## Layout

| Path | Role |
|------|------|
| `application-root.yaml` | App-of-Apps (`ai-model-security-platform`) → syncs `apps/` |
| `apps/*.yaml` | One Application per overlay / zone (sync-waves 0–16) |
| `apps/application-model-test.yaml` | Watches `qwen3-8b-fp8-verified.yaml` → `model-test` |
| `../../gitops-scripts.sh` | Step-by-step runbook: single apply + post-sync (like `script.sh`) |

**Not synced by Argo:** `overlays/16-test-serving` (gitignored generated secrets/manifests) — applied in `gitops-scripts.sh` post-sync.

## Prerequisites

1. OpenShift GitOps operator Ready (`Application` CRD present).
2. Push this repo to a remote Argo CD can reach; set `repoURL` / `targetRevision` in `application-root.yaml` and every file under `apps/` if using a fork.
3. Edit `instances/gateway/gateway.yaml` hostname (`REPLACE_WITH_CLUSTER_APPS_DOMAIN`).
4. Prepare `minio-s3-secret.yaml` and `quay-secret.yaml` from templates (gitignored).
5. GPU MachineSet if needed: `infra/prereqs/ocp-gpu-setup/README.md`.

## Deploy (recommended)

Copy/paste phases from `gitops-scripts.sh` (same style as `script.sh` — do not run it end-to-end):

```bash
# Phase 0 — single apply of App-of-Apps root:
oc apply -k ./instances/gitops/
# or: oc apply -k ./overlays/17-gitops/
oc get applications -n openshift-gitops -l app.kubernetes.io/part-of=ai-model-security-pipeline
```

Then continue with Phases 1–6 in `gitops-scripts.sh` (MinIO wait, secrets, builds, authorino, overlay 16, optional fetch/PipelineRun).
## Sync waves (child apps)

| Wave | Application | Path |
|------|-------------|------|
| 0 | `ai-sec-00-gpu-operators` | `overlays/00-gpu-operators` |
| 1 | `ai-sec-01-gpu-instances` | `overlays/01-gpu-instances` |
| 2 | `ai-sec-02-operators` | `overlays/02-operators` |
| 3 | `ai-sec-model-ingress`, `ai-sec-04-zones` | `instances/model-ingress`, `overlays/04-zones` |
| 4 | `ai-sec-03-operator-instances` | `overlays/03-operator-instances` |
| 5–10 | storage → builds → Tekton → Chains | `overlays/05`–`10` |
| 11–15 | RHOAI → gateway → authorino → hardware | `overlays/11`–`15` |
| 16 | `model-test-verified-models` | `instances/model-test` (verified yaml only) |

## Verified model promotion

1. Pipeline pass → `publish-artifact` writes `s3://models-verified/<model-id>/<version>/`.
2. Commit updated `instances/model-test/qwen3-8b-fp8-verified.yaml` (or rely on post-sync generate + push).
3. `model-test-verified-models` Application self-heals into `model-test`.

## Rollback

Revert the Git commit that changed the synced path. Argo CD self-heals. To remove the platform App-of-Apps:

```bash
oc delete application ai-model-security-platform -n openshift-gitops
# Child apps are pruned when the root uses prune: true
```
