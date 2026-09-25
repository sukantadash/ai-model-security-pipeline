# AI Model Security Pipeline — GitOps deployment runbook
# Design: README.md, instances/gitops/README.md, script.sh (manual overlay path)
# App-of-Apps: instances/gitops/application-root.yaml → instances/gitops/apps/
#
# Prerequisites:
#   oc login ...
#   OpenShift GitOps operator Ready (Application CRD present)
#   GPU nodes: infra/prereqs/ocp-gpu-setup/README.md (MachineSet still manual)
#   Edit repoURL / targetRevision in instances/gitops/application-root.yaml
#     and instances/gitops/apps/*.yaml if using a fork
#   Edit instances/gateway/gateway.yaml hostname (REPLACE_WITH_CLUSTER_APPS_DOMAIN)
#   Quay + MinIO secrets: quay-secret.yaml, minio-s3-secret.yaml from templates
#   Hugging Face token for gated models (model-ingress)
#
# Run phase-by-phase: copy/paste each phase block into your shell
# (do not run bash gitops-scripts.sh end-to-end).

cd "$(dirname "$0")"

# Platform namespaces — override via environment before running commands below.
export NS_MODEL_INGRESS="${NS_MODEL_INGRESS:-model-ingress}"
export NS_MODEL_EVAL="${NS_MODEL_EVAL:-model-eval}"
export NS_MODEL_TEST="${NS_MODEL_TEST:-model-test}"
export NS_MODEL_SANDBOX="${NS_MODEL_SANDBOX:-model-sandbox}"
export NS_BUILD_IMAGE="${NS_BUILD_IMAGE:-build-image}"
export NS_MINIO="${NS_MINIO:-minio-system}"
export NS_GITOPS="${NS_GITOPS:-openshift-gitops}"

# =============================================================================
# Phase 0: Apply App-of-Apps (single apply)
# Overlay: 17-gitops → instances/gitops (root Application only)
# Children sync overlays 00–15 + model-ingress + model-test promotion (waves 0–16).
# =============================================================================
oc apply -k ./instances/gitops/
# Equivalent:
#   oc apply -k ./overlays/17-gitops/
#
# Verify root + children:
oc get application ai-model-security-platform -n "${NS_GITOPS}"
oc get applications -n "${NS_GITOPS}" -l app.kubernetes.io/part-of=ai-model-security-pipeline
#
# Watch sync (operator CSV / KataConfig can take a long time):
#   oc get applications -n "${NS_GITOPS}" -w
# Expect child apps: ai-sec-00-gpu-operators … ai-sec-15-hardware-profile,
#   ai-sec-model-ingress, model-test-verified-models

# =============================================================================
# Phase 1: Wait for storage (MinIO from overlay 05 via Argo)
# =============================================================================
oc rollout status deployment/minio -n "${NS_MINIO}" --timeout=300s
oc wait --for=condition=Available deployment/minio -n "${NS_MINIO}" --timeout=600s
oc wait --for=condition=complete job/minio-bucket-init -n "${NS_MINIO}" --timeout=300s
oc get route minio-api minio-console -n "${NS_MINIO}"

# =============================================================================
# Phase 2: Zone secrets (not in Git)
# ingress-models PVC: instances/model-ingress (App ai-sec-model-ingress / Phase 0 sync)
# verified-models PVC: instances/model-test-ns via overlay 04-zones
# =============================================================================

# cp minio-s3-secret.yaml.template minio-s3-secret.yaml   # edit credentials first
for ns in "${NS_MODEL_INGRESS}" "${NS_MODEL_EVAL}" "${NS_MODEL_SANDBOX}" "${NS_MODEL_TEST}"; do
  oc apply -f minio-s3-secret.yaml -n "${ns}"
done
for ns in "${NS_MODEL_INGRESS}" "${NS_MODEL_EVAL}" "${NS_MODEL_SANDBOX}" "${NS_MODEL_TEST}"; do
  oc annotate secret minio-s3 -n "${ns}" --overwrite \
    "serving.kserve.io/s3-endpoint=minio.minio-system.svc:9000" \
    "serving.kserve.io/s3-usehttps=0" \
    "serving.kserve.io/s3-region=us-east-1" \
    "serving.kserve.io/s3-verifyssl=0" \
    "serving.kserve.io/s3-useanoncredential=false" \
    "serving.kserve.io/s3-usevirtualbucket=false" || true
done
for ns in "${NS_MODEL_INGRESS}" "${NS_MODEL_EVAL}" "${NS_MODEL_SANDBOX}" "${NS_MODEL_TEST}"; do
  oc get secret minio-s3 -n "${ns}"
done

# cp quay-secret.yaml.template quay-secret.yaml             # edit credentials first
oc apply -f quay-secret.yaml -n "${NS_BUILD_IMAGE}"
oc secrets link builder sudash-modelpipeline-pull-secret -n "${NS_BUILD_IMAGE}"
oc apply -f quay-secret.yaml -n "${NS_MODEL_INGRESS}"
oc apply -f quay-secret.yaml -n "${NS_MODEL_EVAL}"
oc apply -f quay-secret.yaml -n "${NS_MODEL_TEST}"

# Hugging Face token (ingress only, gated models) — replace <your-token>:
oc create secret generic hf-token -n "${NS_MODEL_INGRESS}" \
  --from-literal=HF_TOKEN=<your-token>

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
# Phase 4: Authorino serving-cert annotate
# =============================================================================
oc annotate svc/authorino-authorino-authorization \
  service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert \
  -n kuadrant-system --overwrite || true

# =============================================================================
# Phase 5: Test serving (overlay 16 — not an Argo app; gitignored generated files)
# =============================================================================
export MODEL_CONN_VERSION="${MODEL_CONN_VERSION:-d4xs2}"
export MODEL_CONN_NAME="redhatai-qwen3-8b-fp8-dynamic-${MODEL_CONN_VERSION}"

if [[ ! -f minio-s3-secret.yaml ]]; then
  echo "minio-s3-secret.yaml missing; cp minio-s3-secret.yaml.template and edit credentials (Phase 2)" >&2
else
  MINIO_USER="$(awk -F': ' '/AWS_ACCESS_KEY_ID:/{print $2; exit}' minio-s3-secret.yaml | tr -d ' \"')"
  MINIO_PASS="$(awk -F': ' '/AWS_SECRET_ACCESS_KEY:/{print $2; exit}' minio-s3-secret.yaml | tr -d ' \"')"
  sed -e "s/PLACEHOLDER/${MODEL_CONN_VERSION}/g" \
      -e "s/CHANGE_ME_MINIO_ROOT_USER/${MINIO_USER}/g" \
      -e "s/CHANGE_ME_MINIO_ROOT_PASSWORD/${MINIO_PASS}/g" \
    instances/model-test/model-connection-secret.yaml.template \
    > instances/model-test/model-connection-secret.yaml
fi

sed "s/PLACEHOLDER/${MODEL_CONN_VERSION}/g" \
  instances/model-test/qwen3-8b-fp8-verified.yaml.template \
  > instances/model-test/qwen3-8b-fp8-verified.yaml

oc apply -k ./overlays/16-test-serving/ -n "${NS_MODEL_TEST}"
oc get llminferenceservice -n "${NS_MODEL_TEST}"

# =============================================================================
# Phase 6: Fetch model + live PipelineRun (optional)
# =============================================================================
# oc apply -f ./instances/model-ingress-fetch/model-fetch-job.yaml -n "${NS_MODEL_INGRESS}"
# oc wait --for=condition=complete job/model-fetch -n "${NS_MODEL_INGRESS}" --timeout=7200s
#
# Edit git-url in pipelinerun-example.yaml first, then:
# oc create -f ./instances/tekton-pipeline/pipelinerun-example.yaml -n "${NS_MODEL_EVAL}"
# oc get pipelinerun -n "${NS_MODEL_EVAL}" -w

# =============================================================================
# Cleanup — uncomment only when tearing down
# =============================================================================
# oc delete application ai-model-security-platform -n "${NS_GITOPS}"
# oc delete applications -n "${NS_GITOPS}" -l app.kubernetes.io/part-of=ai-model-security-pipeline
# oc delete -k ./overlays/16-test-serving/ -n "${NS_MODEL_TEST}"
