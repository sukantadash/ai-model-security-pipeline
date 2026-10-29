# Install — GitOps deployment runbook

Phase-by-phase install for the AI Model Security Pipeline via OpenShift GitOps (App-of-Apps). Commands match [`gitops-scripts.sh`](gitops-scripts.sh).

> **Do not run** `bash gitops-scripts.sh` end-to-end. Copy and paste each phase block into your shell.



```bash
oc login --token=<token> --server=https://api.<cluster>:6443
./deploy.sh
```

---

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| `oc login` as cluster-admin | OpenShift cluster ready |
| OpenShift GitOps operator | `Application` CRD present (Ready) |
| **Two GPU workers** | One for `model-sandbox` (eval serve), one for `model-test` (verified serve). A single GPU blocks the next PipelineRun while `model-test` keeps serving. Setup: [infra/prereqs/ocp-gpu-setup/README.md](infra/prereqs/ocp-gpu-setup/README.md) (MachineSet still manual) |
| Fork edits (if needed) | Set `repoURL` / `targetRevision` in `instances/gitops/application-root.yaml` and `instances/gitops/apps/*.yaml` |
| Gateway hostname | Set `APPS_DOMAIN` from the cluster and edit `instances/gateway/gateway.yaml` (`REPLACE_WITH_CLUSTER_APPS_DOMAIN`) |
| Credentials | `cp .env.example .env` and set `HF_TOKEN`, `QUAY_*`, `MINIO_ROOT_*`, `MODELCAR_IMAGE` |

**Apps domain:**

```bash
APPS_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
echo "inference-gateway.${APPS_DOMAIN}"
```

**Model weights:** ModelCar OCI on Quay (`:unverified` → `:verified-score-build`*). MinIO stores scan results only. Cluster Secrets are created from `.env` — no quay/minio YAML files.

---

## Environment

From the repo root:

```bash
cd "$(dirname "$0")"   # or: cd /path/to/ai-model-security-pipeline
source ./.env

export QUAY_SERVER="${QUAY_SERVER:-quay.io}"
export QUAY_EMAIL="${QUAY_EMAIL:-}"
export QUAY_SECRET_NAME="${QUAY_SECRET_NAME:-sudash-modelpipeline-pull-secret}"

export NS_MODEL_INGRESS="${NS_MODEL_INGRESS:-model-ingress}"
export NS_MODEL_EVAL="${NS_MODEL_EVAL:-model-eval}"
export NS_MODEL_TEST="${NS_MODEL_TEST:-model-test}"
export NS_MODEL_SANDBOX="${NS_MODEL_SANDBOX:-model-sandbox}"
export NS_BUILD_IMAGE="${NS_BUILD_IMAGE:-build-image}"
export NS_MINIO="${NS_MINIO:-minio-system}"
export NS_GITOPS="${NS_GITOPS:-openshift-gitops}"
```

---

## Phase -1: Size Argo CD application-controller

Default limits are too small for this App-of-Apps and many child Applications (avoids OOMKilled / stuck syncs).

```bash
oc patch argocd openshift-gitops -n "${NS_GITOPS}" --type merge -p '
spec:
  controller:
    resources:
      requests:
        cpu: 500m
        memory: 4Gi
      limits:
        cpu: "2"
        memory: 8Gi
'
oc delete pod -n "${NS_GITOPS}" -l app.kubernetes.io/name=openshift-gitops-application-controller --ignore-not-found
oc rollout status statefulset/openshift-gitops-application-controller -n "${NS_GITOPS}" --timeout=300s
oc get pods -n "${NS_GITOPS}" | grep application-controller
```

Expect Ready `1/1` (not OOMKilled / CrashLoopBackOff) before Phase 0.

---

## Phase 0: Apply App-of-Apps

Single apply. Overlay `17-gitops` → `instances/gitops` (root Application only). Children sync overlays `00`–`15` plus model-ingress and model-test promotion (waves 0–16).

```bash
oc apply -k ./instances/gitops/

# Verify root + children
oc get application ai-model-security-platform -n "${NS_GITOPS}"
oc get applications -n "${NS_GITOPS}" -l app.kubernetes.io/part-of=ai-model-security-pipeline
```

RHCL (connectivity-link) uses `installPlanApproval: Automatic` — wait for CSV:

```bash
# oc get application ai-sec-02-operators -n "${NS_GITOPS}"
oc get csv -n kuadrant-system
oc wait --for=jsonpath='{.status.phase}'=Succeeded csv -n kuadrant-system --timeout=600s || true
```

Enable OpenShift console plugins (Pipelines / GitOps menus). Operator installs the ConsolePlugin CRs; they stay hidden until listed on `console.operator/cluster`.

```bash
oc wait --for=condition=Available deployment/pipelines-console-plugin \
  -n openshift-pipelines --timeout=300s || true
for plugin in pipelines-console-plugin gitops-plugin; do
  oc get consoleplugin "${plugin}" >/dev/null 2>&1 || continue
  if ! oc get console.operator cluster -o jsonpath='{.spec.plugins[*]}' | grep -qw "${plugin}"; then
    oc patch console.operator cluster --type json \
      -p "[{\"op\":\"add\",\"path\":\"/spec/plugins/-\",\"value\":\"${plugin}\"}]"
  fi
done
oc get console.operator cluster -o jsonpath='plugins={.spec.plugins}{"\n"}'
```

---

## Phase 1: MinIO root from `.env`, wait for storage

Overlay `05` is synced via Argo. Create the MinIO root secret, then wait for the Deployment and bucket-init Job.

```bash
oc create secret generic minio-root -n "${NS_MINIO}" \
  --from-literal=MINIO_ROOT_USER="${MINIO_ROOT_USER}" \
  --from-literal=MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD}" \
  --dry-run=client -o yaml | oc apply -f -
oc rollout restart deployment/minio -n "${NS_MINIO}" || true
oc rollout status deployment/minio -n "${NS_MINIO}" --timeout=300s
oc wait --for=condition=Available deployment/minio -n "${NS_MINIO}" --timeout=600s
oc wait --for=condition=complete job/minio-bucket-init -n "${NS_MINIO}" --timeout=300s
oc get route minio-api minio-console -n "${NS_MINIO}"
```

---

## Phase 2: Zone secrets from `.env`

No `quay-secret.yaml` / `minio-s3-secret.yaml` — Secrets are created from `.env`.

### MinIO S3 credentials (KServe annotations)

```bash
for ns in "${NS_MODEL_INGRESS}" "${NS_MODEL_EVAL}" "${NS_MODEL_SANDBOX}" "${NS_MODEL_TEST}"; do
  oc create secret generic minio-s3 -n "${ns}" \
    --from-literal=MINIO_ENDPOINT=http://minio.minio-system.svc:9000 \
    --from-literal=AWS_ACCESS_KEY_ID="${MINIO_ROOT_USER}" \
    --from-literal=AWS_SECRET_ACCESS_KEY="${MINIO_ROOT_PASSWORD}" \
    --from-literal=AWS_REGION=us-east-1 \
    --from-literal=AWS_ENDPOINT_URL=http://minio.minio-system.svc:9000 \
    --from-literal=AWS_DEFAULT_REGION=us-east-1 \
    --from-literal=S3_USE_HTTPS=0 \
    --from-literal=S3_VERIFY_SSL=0 \
    --from-literal=AWS_S3_FORCE_PATH_STYLE=true \
    --dry-run=client -o yaml | oc apply -f -
  oc annotate secret minio-s3 -n "${ns}" --overwrite \
    "serving.kserve.io/s3-endpoint=minio.minio-system.svc:9000" \
    "serving.kserve.io/s3-usehttps=0" \
    "serving.kserve.io/s3-region=us-east-1" \
    "serving.kserve.io/s3-verifyssl=0" \
    "serving.kserve.io/s3-useanoncredential=false" \
    "serving.kserve.io/s3-usevirtualbucket=false"
done
```

### Quay pull/push secrets and SA links

```bash
for ns in "${NS_MODEL_INGRESS}" "${NS_MODEL_EVAL}" "${NS_MODEL_SANDBOX}" "${NS_BUILD_IMAGE}" "${NS_MODEL_TEST}"; do
  oc create secret docker-registry "${QUAY_SECRET_NAME}" \
    --docker-server="${QUAY_SERVER}" \
    --docker-username="${QUAY_USERNAME}" \
    --docker-password="${QUAY_PASSWORD}" \
    --docker-email="${QUAY_EMAIL}" \
    -n "${ns}" \
    --dry-run=client -o yaml | oc apply -f -
done

oc secrets link builder "${QUAY_SECRET_NAME}" -n "${NS_BUILD_IMAGE}"
```

ModelCar SA + ConfigMap come from Argo `ai-sec-model-ingress` (`instances/model-ingress`). Ensure that Application is Synced before linking Quay / SCC for the one-shot Job.

```bash
for _ in $(seq 1 60); do
  oc get sa model-fetch -n "${NS_MODEL_INGRESS}" >/dev/null 2>&1 && break
  sleep 5
done
oc get sa model-fetch -n "${NS_MODEL_INGRESS}"
oc secrets link model-fetch "${QUAY_SECRET_NAME}" -n "${NS_MODEL_INGRESS}" --for=pull,mount 2>/dev/null \
  || oc secrets link model-fetch "${QUAY_SECRET_NAME}" -n "${NS_MODEL_INGRESS}" || true
oc adm policy add-scc-to-user privileged -z model-fetch -n "${NS_MODEL_INGRESS}" || true
for sa in default model-eval-pipeline; do
  oc secrets link "${sa}" "${QUAY_SECRET_NAME}" -n "${NS_MODEL_EVAL}" --for=pull 2>/dev/null || true
done
oc secrets link default "${QUAY_SECRET_NAME}" -n "${NS_MODEL_SANDBOX}" --for=pull 2>/dev/null || true
oc secrets link default "${QUAY_SECRET_NAME}" -n "${NS_MODEL_TEST}" --for=pull 2>/dev/null || true
```

### Hugging Face token

```bash
oc create secret generic hf-token -n "${NS_MODEL_INGRESS}" \
  --from-literal=HF_TOKEN="${HF_TOKEN}" \
  --dry-run=client -o yaml | oc apply -f -
```

---

## Phase 3: Build scanner images

Binary BuildConfigs from overlay `06`. Wait until `ai-sec-06-builds` is Synced:

```bash
# oc get application ai-sec-06-builds -n "${NS_GITOPS}"
for bc in model-fetch static-scan dynamic-test capability-eval adversarial-test score-gate publish; do
  oc start-build "ai-security-${bc}" --from-dir="builds/${bc}" --follow -n "${NS_BUILD_IMAGE}"
done

oc get istag -n "${NS_BUILD_IMAGE}" | grep ai-security

for ns in "${NS_MODEL_INGRESS}" "${NS_MODEL_EVAL}" "${NS_MODEL_SANDBOX}"; do
  oc policy add-role-to-group system:image-puller "system:serviceaccounts:${ns}" -n "${NS_BUILD_IMAGE}"
done
```

---

## Phase 4: Authorino serving-cert

Authorino CR needs `authorino-server-cert` before it creates its own Service. Create a stub Service with the OpenShift serving-cert annotation first (or annotate the existing Service).

### Check Authorino status

```bash
oc get authorino authorino -n kuadrant-system \
  -o jsonpath='Ready={.status.conditions[?(@.type=="Ready")].status} reason={.status.conditions[?(@.type=="Ready")].reason}{"\n"}{.status.conditions[?(@.type=="Ready")].message}{"\n"}'
oc get secret authorino-server-cert -n kuadrant-system
oc get svc authorino-authorino-authorization -n kuadrant-system \
  -o jsonpath='ann={.metadata.annotations.service\.beta\.openshift\.io/serving-cert-secret-name}{"\n"}'
```

### Bootstrap cert (apply stub Service **or** annotate)

```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: authorino-authorino-authorization
  namespace: kuadrant-system
  annotations:
    service.beta.openshift.io/serving-cert-secret-name: authorino-server-cert
spec:
  ports:
  - name: grpc
    port: 50051
    protocol: TCP
    targetPort: 50051
  selector:
    authorino-resource: authorino
  type: ClusterIP
EOF
```

Or, if the Service already exists:

```bash
oc annotate svc/authorino-authorino-authorization \
  service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert \
  -n kuadrant-system --overwrite || true
```

Force reconcile and wait until Ready:

```bash
oc annotate authorino authorino -n kuadrant-system reconcile="$(date +%s)" --overwrite

oc get secret authorino-server-cert -n kuadrant-system
oc wait --for=condition=Ready authorino/authorino -n kuadrant-system --timeout=300s
oc get authorino authorino -n kuadrant-system \
  -o jsonpath='Ready={.status.conditions[?(@.type=="Ready")].status} reason={.status.conditions[?(@.type=="Ready")].reason}{"\n"}'
```

---

## Phase 5: Build ModelCar (`:unverified`) + PipelineRun

**Prerequisites:** Argo apps `07`–`12` Synced (Tasks, Pipeline, Triggers, Chains, RHOAI).

`MODELCAR_IMAGE` is the shared repo (Job + PipelineRun). Tags: `<model-id>-unverified` → `<model-id>-verified-<score>-<version>`.

Edit `git-url` / `serving-yaml` / `model-id` in `instances/tekton-pipeline/pipelinerun-example.yaml` as needed. After ModelCar-related changes, rebuild publish:

```bash
oc start-build ai-security-publish --from-dir=builds/publish --follow -n build-image
```

Wait until RHOAI / Model Registry are Ready (needed before `publish-artifact`):

```bash
# oc get application ai-sec-11-rhoai ai-sec-12-rhoai-dashboard -n "${NS_GITOPS}"
# oc wait --for=jsonpath='{.status.phase}'=Ready dscinitialization/default-dsci --timeout=600s
# oc wait --for=jsonpath='{.status.phase}'=Ready datasciencecluster/default-dsc --timeout=600s
# oc wait --for=condition=Available mr/model-registry -n rhoai-model-registries --timeout=600s
```

### One-shot ModelCar Job

SA + `modelcar-build` ConfigMap are already synced via model-ingress:

```bash
oc delete job/model-fetch -n "${NS_MODEL_INGRESS}" --ignore-not-found
oc apply -f ./instances/model-ingress-fetch/model-fetch-job.yaml -n "${NS_MODEL_INGRESS}"
oc wait --for=condition=complete job/model-fetch -n "${NS_MODEL_INGRESS}" --timeout=7200s
```

### Start the pipeline

Confirm sandbox has no leftover eval CR, clean `model-test`, then create the PipelineRun. Set `modelcar-image` in `pipelinerun-example.yaml` to match Job `MODELCAR_IMAGE` first.

```bash
oc get llminferenceservice -n "${NS_MODEL_SANDBOX}"
oc get pipeline.tekton.dev model-security-pipeline -n "${NS_MODEL_EVAL}" \
  -o jsonpath='{.spec.params[?(@.name=="modelcar-image")].name}{"\n"}'

oc get llminferenceservice -n "${NS_MODEL_TEST}"
oc delete llminferenceservice -n "${NS_MODEL_TEST}" --all

oc create -f ./instances/tekton-pipeline/pipelinerun-example.yaml -n "${NS_MODEL_EVAL}"
oc get pipelinerun -n "${NS_MODEL_EVAL}" -w
```

Useful checks while the run progresses:

```bash
# After serve-llm-start: CR is in model-sandbox (not model-eval)
oc get llminferenceservice,svc,pod -n "${NS_MODEL_SANDBOX}"

# After finally: CR deleted, namespace remains
oc get ns "${NS_MODEL_SANDBOX}"
oc get llminferenceservice -n "${NS_MODEL_SANDBOX}"
```

On auto-pass or review, `publish-artifact` retags ModelCar to `:verified-score-buildVERSION`, registers Model Registry (`oci://` URI), and `oc apply`s the serving YAML with the placeholder replaced.

---

## Phase 6: Test serving smoke

Overlay `16` is applied by `publish-artifact`. Optional bootstrap:

```bash
# oc apply -k ./overlays/16-test-serving/ -n "${NS_MODEL_TEST}"
```

Smoke test:

```bash
GATEWAY_HOST=$(oc get gateway openshift-ai-inference -n openshift-ingress \
  -o jsonpath='{.spec.listeners[0].hostname}')
TOKEN="$(oc create token test-user -n "${NS_MODEL_TEST}")"
curl -sS "https://${GATEWAY_HOST}/${NS_MODEL_TEST}/qwen3-8b-fp8/v1/models" \
  -H "Authorization: Bearer ${TOKEN}" | jq .
```

---

## Cleanup

Uncomment / run only when tearing down:

```bash
# oc delete application ai-model-security-platform -n "${NS_GITOPS}"
# oc delete applications -n "${NS_GITOPS}" -l app.kubernetes.io/part-of=ai-model-security-pipeline
# oc delete -k ./overlays/16-test-serving/ -n "${NS_MODEL_TEST}"
```

---
