# AI Model Security Pipeline — GitOps deployment runbook
# Design: README.md, instances/gitops/README.md, script.sh (manual overlay path)
# App-of-Apps: instances/gitops/application-root.yaml → instances/gitops/apps/
#
# Prerequisites:
#   oc login ...
#   OpenShift GitOps operator Ready (Application CRD present)
#   GPU nodes: two GPU workers required — one for model-sandbox (pipeline eval
#     serve-llm-start) and one for model-test (verified serve after publish).
#     A single GPU blocks the next PipelineRun while model-test keeps serving.
#     Setup: infra/prereqs/ocp-gpu-setup/README.md (MachineSet still manual)
#   Edit repoURL / targetRevision in instances/gitops/application-root.yaml
#     and instances/gitops/apps/*.yaml if using a fork
#   Set APPS_DOMAIN from this cluster:
#     APPS_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
#     echo "inference-gateway.${APPS_DOMAIN}"
#   Edit instances/gateway/gateway.yaml hostname (REPLACE_WITH_CLUSTER_APPS_DOMAIN)
#   Credentials: cp .env.example .env and set HF_TOKEN, QUAY_*, MINIO_ROOT_*, MODELCAR_IMAGE
#   (gitops-scripts.sh creates cluster Secrets from .env — no quay/minio yaml files)
#   Model weights: ModelCar OCI on Quay (:unverified → :verified-score-build*). MinIO = scans only.
#
# Run phase-by-phase: copy/paste each phase block into your shell
# (do not run bash gitops-scripts.sh end-to-end).

cd "$(dirname "$0")"

source ./.env

export QUAY_SERVER="${QUAY_SERVER:-quay.io}"
export QUAY_EMAIL="${QUAY_EMAIL:-}"
export QUAY_SECRET_NAME="${QUAY_SECRET_NAME:-sudash-modelpipeline-pull-secret}"

# Platform namespaces — override via environment before running commands below.
export NS_MODEL_INGRESS="${NS_MODEL_INGRESS:-model-ingress}"
export NS_MODEL_EVAL="${NS_MODEL_EVAL:-model-eval}"
export NS_MODEL_TEST="${NS_MODEL_TEST:-model-test}"
export NS_MODEL_SANDBOX="${NS_MODEL_SANDBOX:-model-sandbox}"
export NS_BUILD_IMAGE="${NS_BUILD_IMAGE:-build-image}"
export NS_MINIO="${NS_MINIO:-minio-system}"
export NS_GITOPS="${NS_GITOPS:-openshift-gitops}"

# =============================================================================
# Phase -1: Size Argo CD application-controller (avoid OOMKilled / stuck syncs)
# Default limits are too small for this App-of-Apps + many child Applications.
# =============================================================================
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
# Expect Ready 1/1 (not OOMKilled / CrashLoopBackOff) before Phase 0.

# =============================================================================
# Phase 0: Apply App-of-Apps (single apply)
# Overlay: 17-gitops → instances/gitops (root Application only)
# Children sync overlays 00–15 + model-ingress + model-test promotion (waves 0–16).
# =============================================================================
oc apply -k ./instances/gitops/

# Verify root + children:
oc get application ai-model-security-platform -n "${NS_GITOPS}"
oc get applications -n "${NS_GITOPS}" -l app.kubernetes.io/part-of=ai-model-security-pipeline

# RHCL (connectivity-link) uses installPlanApproval: Automatic — wait for CSV:
#   oc get application ai-sec-02-operators -n "${NS_GITOPS}"
oc get csv -n kuadrant-system
oc wait --for=jsonpath='{.status.phase}'=Succeeded csv -n kuadrant-system --timeout=600s || true

# Enable OpenShift console plugins (Pipelines / GitOps menus). Operator installs the
# ConsolePlugin CRs; they stay hidden until listed on console.operator/cluster.
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

# =============================================================================
# Phase 1: MinIO root from .env, then wait for storage (overlay 05 via Argo)
# =============================================================================
oc create secret generic minio-root -n "${NS_MINIO}" \
  --from-literal=MINIO_ROOT_USER="${MINIO_ROOT_USER}" \
  --from-literal=MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD}" \
  --dry-run=client -o yaml | oc apply -f -
oc rollout restart deployment/minio -n "${NS_MINIO}" || true
oc rollout status deployment/minio -n "${NS_MINIO}" --timeout=300s
oc wait --for=condition=Available deployment/minio -n "${NS_MINIO}" --timeout=600s
oc wait --for=condition=complete job/minio-bucket-init -n "${NS_MINIO}" --timeout=300s
oc get route minio-api minio-console -n "${NS_MINIO}"

# =============================================================================
# Phase 2: Zone secrets from .env (no quay-secret.yaml / minio-s3-secret.yaml)
# =============================================================================
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
# ModelCar SA + ConfigMap come from Argo ai-sec-model-ingress (instances/model-ingress).
# Ensure ai-sec-model-ingress is Synced before linking Quay / SCC for the one-shot Job.
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

oc create secret generic hf-token -n "${NS_MODEL_INGRESS}" \
  --from-literal=HF_TOKEN="${HF_TOKEN}" \
  --dry-run=client -o yaml | oc apply -f -

# =============================================================================
# Phase 3: Build scanner images (Binary BuildConfigs from overlay 06)
# =============================================================================
# Wait until ai-sec-06-builds is Synced before starting builds:
#   oc get application ai-sec-06-builds -n "${NS_GITOPS}"
for bc in model-fetch static-scan dynamic-test capability-eval adversarial-test score-gate publish; do
  oc start-build "ai-security-${bc}" --from-dir="builds/${bc}" --follow -n "${NS_BUILD_IMAGE}"
done

oc get istag -n "${NS_BUILD_IMAGE}" | grep ai-security

for ns in "${NS_MODEL_INGRESS}" "${NS_MODEL_EVAL}" "${NS_MODEL_SANDBOX}"; do
  oc policy add-role-to-group system:image-puller "system:serviceaccounts:${ns}" -n "${NS_BUILD_IMAGE}"
done

# =============================================================================
# Phase 4: Authorino serving-cert (bootstrap Service → secret → Authorino Ready)
# Authorino CR needs authorino-server-cert before it creates its own Service;
# create a stub Service with the OpenShift serving-cert annotation first.
# =============================================================================

#Check Authorino status:
oc get authorino authorino -n kuadrant-system \
  -o jsonpath='Ready={.status.conditions[?(@.type=="Ready")].status} reason={.status.conditions[?(@.type=="Ready")].reason}{"\n"}{.status.conditions[?(@.type=="Ready")].message}{"\n"}'
oc get secret authorino-server-cert -n kuadrant-system
oc get svc authorino-authorino-authorization -n kuadrant-system \
  -o jsonpath='ann={.metadata.annotations.service\.beta\.openshift\.io/serving-cert-secret-name}{"\n"}'



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

#OR

oc annotate svc/authorino-authorino-authorization \
  service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert \
  -n kuadrant-system --overwrite || true

# Force Authorino reconcile
oc annotate authorino authorino -n kuadrant-system reconcile="$(date +%s)" --overwrite


oc get secret authorino-server-cert -n kuadrant-system
oc wait --for=condition=Ready authorino/authorino -n kuadrant-system --timeout=300s
oc get authorino authorino -n kuadrant-system \
  -o jsonpath='Ready={.status.conditions[?(@.type=="Ready")].status} reason={.status.conditions[?(@.type=="Ready")].reason}{"\n"}'

# =============================================================================
# Phase 5: Build ModelCar (:unverified) + live PipelineRun
# Prerequisites: Argo apps 07–12 Synced (Tasks, Pipeline, Triggers, Chains, RHOAI).
# MODELCAR_IMAGE is shared repo quay.io/sudash/ai-model-security-pipeline (Job + PipelineRun).
# Tags: <model-id>-unverified → <model-id>-verified-<score>-<version>.
# Edit git-url / serving-yaml / model-id in pipelinerun-example.yaml as needed.
# Rebuild publish image after ModelCar changes: oc start-build ai-security-publish --from-dir=builds/publish --follow -n build-image
# =============================================================================
# Wait until RHOAI / Model Registry are Ready (needed before publish-artifact):
#   oc get application ai-sec-11-rhoai ai-sec-12-rhoai-dashboard -n "${NS_GITOPS}"
#   oc wait --for=jsonpath='{.status.phase}'=Ready dscinitialization/default-dsci --timeout=600s
#   oc wait --for=jsonpath='{.status.phase}'=Ready datasciencecluster/default-dsc --timeout=600s
#   oc wait --for=condition=Available mr/model-registry -n rhoai-model-registries --timeout=600s

# One-shot Job only (SA + modelcar-build ConfigMap already synced via model-ingress):
oc delete job/model-fetch -n "${NS_MODEL_INGRESS}" --ignore-not-found
oc apply -f ./instances/model-ingress-fetch/model-fetch-job.yaml -n "${NS_MODEL_INGRESS}"
oc wait --for=condition=complete job/model-fetch -n "${NS_MODEL_INGRESS}" --timeout=7200s

# Confirm sandbox is empty of a leftover eval CR, then start the pipeline:
oc get llminferenceservice -n "${NS_MODEL_SANDBOX}"
oc get pipeline.tekton.dev model-security-pipeline -n "${NS_MODEL_EVAL}" \
  -o jsonpath='{.spec.params[?(@.name=="modelcar-image")].name}{"\n"}'

# cleanup any instance running in "${NS_MODEL_TEST}"
oc get llminferenceservice -n "${NS_MODEL_TEST}"
oc delete llminferenceservice -n "${NS_MODEL_TEST}" --all

# Set modelcar-image in pipelinerun-example.yaml to match Job MODELCAR_IMAGE first.
oc create -f ./instances/tekton-pipeline/pipelinerun-example.yaml -n "${NS_MODEL_EVAL}"
oc get pipelinerun -n "${NS_MODEL_EVAL}" -w

#
# After serve-llm-start: CR is in model-sandbox (not model-eval):
#   oc get llminferenceservice,svc,pod -n "${NS_MODEL_SANDBOX}"
# After finally: CR deleted, namespace remains:
#   oc get ns "${NS_MODEL_SANDBOX}"
#   oc get llminferenceservice -n "${NS_MODEL_SANDBOX}"
# Auto-pass or review: publish-artifact retags ModelCar to :verified-score-buildVERSION,
# registers Model Registry (oci:// URI), and oc apply's serving-yaml with placeholder replaced.

# =============================================================================
# Phase 6: Test serving smoke (overlay 16 is applied by publish-artifact; optional bootstrap:
#   oc apply -k ./overlays/16-test-serving/ -n "${NS_MODEL_TEST}")
# =============================================================================

# Smoke test:
GATEWAY_HOST=$(oc get gateway openshift-ai-inference -n openshift-ingress \
  -o jsonpath='{.spec.listeners[0].hostname}')
TOKEN="$(oc create token test-user -n "${NS_MODEL_TEST}")"
curl -sS "https://${GATEWAY_HOST}/${NS_MODEL_TEST}/qwen3-8b-fp8/v1/models" \
  -H "Authorization: Bearer ${TOKEN}" | jq .

# =============================================================================
# Cleanup — uncomment only when tearing down
# =============================================================================
# oc delete application ai-model-security-platform -n "${NS_GITOPS}"
# oc delete applications -n "${NS_GITOPS}" -l app.kubernetes.io/part-of=ai-model-security-pipeline
# oc delete -k ./overlays/16-test-serving/ -n "${NS_MODEL_TEST}"
