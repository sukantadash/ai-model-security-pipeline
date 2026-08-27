# AI Model Security Pipeline — manual deployment runbook
# Reference: HIGH-LEVEL-DESIGN.md, IMPLEMENTATION-PLAN.md
#
# Prerequisites:
#   oc login ...
#   GPU nodes: infra/prereqs/ocp-gpu-setup/README.md
#   Quay org + secrets configured (quay-secret.yaml from template)
#   Hugging Face token for model-ingress
#
# Run phase-by-phase: copy/paste each phase block into your shell (do not run bash script.sh end-to-end).

cd "$(dirname "$0")"

# Platform namespaces — override via environment before running commands below.
export NS_MODEL_INGRESS="${NS_MODEL_INGRESS:-model-ingress}"
export NS_MODEL_EVAL="${NS_MODEL_EVAL:-model-eval}"
export NS_MODEL_TEST="${NS_MODEL_TEST:-model-test}"
export NS_BUILD_IMAGE="${NS_BUILD_IMAGE:-build-image}"
export NS_MINIO="${NS_MINIO:-minio-system}"

# =============================================================================
# Phase 0: Cluster GPU prerequisites
# =============================================================================
# Step 1 — MachineSet (see infra/prereqs/ocp-gpu-setup/README.md):
#   cd infra/prereqs/ocp-gpu-setup && ./machine-set/gpu-machineset.sh
#
# Steps 2–4 — from repo root:
oc apply -k ./overlays/00-gpu-operators/
# Wait for CSV Succeeded (subscription/Available never appears on some clusters):
oc wait --for=jsonpath='{.status.phase}'=Succeeded clusterserviceversion -n openshift-nfd --timeout=600s
oc wait --for=jsonpath='{.status.phase}'=Succeeded clusterserviceversion -n nvidia-gpu-operator --timeout=600s
oc apply -k ./overlays/01-gpu-instances/
#
# Verify:
oc get nodes -l nvidia.com/gpu.present=true
oc get clusterpolicy gpu-cluster-policy -n nvidia-gpu-operator

# =============================================================================
# Phase 1: Operators (Pipelines, GitOps, Service Mesh, RHOAI, …)
# =============================================================================
oc apply -k ./overlays/02-operators/
#
# Wait for CSV Succeeded (includes Sandboxed Containers for Kata — dedicated namespace):
oc get csv -A | grep -E 'pipelines|gitops|rhods|servicemesh|kuadrant|sandboxed'
oc get csv -n openshift-sandboxed-containers-operator
oc get runtimeclass kata   # after KataConfig is applied (Phase 3)
#
# Manual: approve any Manual InstallPlans if required
oc get installplan -A
# oc patch installplan <name> -n <ns> --type merge -p '{"spec":{"approved":true}}'

# =============================================================================
# Phase 2: Three zones — namespaces, NetworkPolicies, pipeline RBAC
# =============================================================================
oc apply -k ./instances/model-ingress/ -n "${NS_MODEL_INGRESS}"
oc apply -k ./instances/model-eval/ -n "${NS_MODEL_EVAL}"
oc apply -k ./instances/model-test/ -n "${NS_MODEL_TEST}"
oc apply -k ./instances/pipeline-rbac/ -n "${NS_MODEL_EVAL}"
#
# Verify:
oc get ns "${NS_MODEL_INGRESS}" "${NS_MODEL_EVAL}" "${NS_MODEL_TEST}"
oc get sa model-eval-pipeline -n "${NS_MODEL_EVAL}"


# =============================================================================
# Phase 3: Operator instances (Tekton Chains, Service Mesh, KataConfig, …)
# =============================================================================
oc apply -k ./overlays/03-operator-instances/
#
# KataConfig triggers worker node reboots (10–60+ min). Verify before Tekton pipeline runs:
oc describe kataconfig cluster-kataconfig
oc get runtimeclass kata

# =============================================================================
# Phase 4: MinIO + eval workspace PVC
# =============================================================================
# Edit instances/minio/secret.yaml (root password), then:
oc apply -k ./instances/minio/ -n "${NS_MINIO}"
# MinIO reads minio-root only at pod start — restart after any password change.
oc rollout restart deployment/minio -n "${NS_MINIO}"
oc rollout status deployment/minio -n "${NS_MINIO}" --timeout=300s
oc wait --for=condition=Available deployment/minio -n "${NS_MINIO}" --timeout=600s
oc wait --for=condition=complete job/minio-bucket-init -n "${NS_MINIO}" --timeout=300s
oc get route minio-api minio-console -n "${NS_MINIO}"
oc apply -f ./instances/storage/eval-workspace-pvc.yaml -n "${NS_MODEL_EVAL}"
oc apply -f ./instances/storage/ingress-models-pvc.yaml -n "${NS_MODEL_INGRESS}"
oc apply -f ./instances/storage/verified-models-pvc.yaml -n "${NS_MODEL_TEST}"

# Restore placeholder in instances/minio/secret.yaml
sed -i '' 's/MINIO_ROOT_PASSWORD: paassword/MINIO_ROOT_PASSWORD: CHANGE_ME_MINIO_ROOT_PASSWORD/' instances/minio/secret.yaml

#
# Secrets (see instances/secrets/README.md):
# cp minio-s3-secret.yaml.template minio-s3-secret.yaml   # edit credentials first
for ns in "${NS_MODEL_INGRESS}" "${NS_MODEL_EVAL}" "${NS_MODEL_TEST}"; do
  oc apply -f minio-s3-secret.yaml -n "${ns}"
done
# cp quay-secret.yaml.template quay-secret.yaml             # edit credentials first
oc apply -f quay-secret.yaml -n "${NS_BUILD_IMAGE}"
oc secrets link builder sudash-modelpipeline-pull-secret -n "${NS_BUILD_IMAGE}"
oc apply -f quay-secret.yaml -n "${NS_MODEL_INGRESS}"
oc apply -f quay-secret.yaml -n "${NS_MODEL_EVAL}"
#
# Hugging Face token (ingress only) — replace <your-token>:
# oc create secret generic hf-token -n "${NS_MODEL_INGRESS}" \
#   --from-literal=HF_TOKEN=<your-token>

# =============================================================================
# Phase 5: Build custom scanner images
# =============================================================================
oc apply -k ./overlays/06-builds/ -n "${NS_BUILD_IMAGE}"
oc apply -f quay-secret.yaml -n "${NS_BUILD_IMAGE}"
oc secrets link builder sudash-modelpipeline-pull-secret -n "${NS_BUILD_IMAGE}"

for bc in model-fetch static-scan dynamic-test dynamic-gpu capability-eval adversarial-test score-gate publish; do
  oc start-build "ai-security-${bc}" --from-dir="builds/${bc}" --follow -n "${NS_BUILD_IMAGE}"
done

oc get istag -n "${NS_BUILD_IMAGE}" | grep ai-security

# Cross-namespace pull (model-ingress Job + model-eval Tekton pull from build-image):
for ns in "${NS_MODEL_INGRESS}" "${NS_MODEL_EVAL}"; do
  oc policy add-role-to-group system:image-puller "system:serviceaccounts:${ns}" -n "${NS_BUILD_IMAGE}"
done

# =============================================================================
# Phase 6: Tekton Tasks
# =============================================================================
oc apply -k ./overlays/07-tekton-tasks/ -n "${NS_MODEL_EVAL}"

# =============================================================================
# Phase 7: Tekton Pipeline
# =============================================================================
oc apply -k ./overlays/08-tekton-pipeline/ -n "${NS_MODEL_EVAL}"

# =============================================================================
# Phase 8: Tekton Triggers
# =============================================================================
oc apply -k ./overlays/09-tekton-triggers/ -n "${NS_MODEL_EVAL}"

# =============================================================================
# Phase 9: Tekton Chains (SLSA / Cosign signing)
# =============================================================================
oc apply -k ./overlays/10-tekton-chains/

# =============================================================================
# Phase 10: Test — HF download → PipelineRun (RedHatAI/Qwen3-8B-FP8-dynamic)
# =============================================================================
oc apply -f ./instances/model-ingress-fetch/model-fetch-job.yaml -n "${NS_MODEL_INGRESS}"
oc wait --for=condition=complete job/model-fetch -n "${NS_MODEL_INGRESS}" --timeout=7200s
#
# Unit-test static-scan TaskRuns (malware, vulnerabilities, license-compliance):
oc create configmap fixture-static-malware -n "${NS_MODEL_EVAL}" \
  --from-file=evil.pkl=./builds/static-scan/testdata/malware/evil.pkl \
  --dry-run=client -o yaml | oc apply -f -
oc create configmap fixture-static-vulnerabilities -n "${NS_MODEL_EVAL}" \
  --from-file=requirements.txt=./builds/static-scan/testdata/vulnerabilities/requirements.txt \
  --dry-run=client -o yaml | oc apply -f -
oc create configmap fixture-static-license -n "${NS_MODEL_EVAL}" \
  --from-file=config.json=./builds/static-scan/testdata/license-compliance/config.json \
  --from-file=LICENSE=./builds/static-scan/testdata/license-compliance/LICENSE \
  --dry-run=client -o yaml | oc apply -f -
oc create -f ./instances/tekton-tasks/static-scan-unit-taskruns.yaml -n "${NS_MODEL_EVAL}"
oc wait --for=condition=Succeeded taskrun -l test=static-scan-unit -n "${NS_MODEL_EVAL}" --timeout=600s
oc get taskrun -l test=static-scan-unit -n "${NS_MODEL_EVAL}"
#
# Unit-test dynamic-scan TaskRuns (isolated-runtime, behavior, abnormal-resources, basic-inference):
# Local (no cluster): bash builds/dynamic-test/scripts/run-unit-tests.sh
oc create configmap fixture-dynamic-isolated-runtime -n "${NS_MODEL_EVAL}" \
  --from-file=README.txt=./builds/dynamic-test/testdata/isolated-runtime/README.txt \
  --dry-run=client -o yaml | oc apply -f -
oc create configmap fixture-dynamic-behavior -n "${NS_MODEL_EVAL}" \
  --from-file=falco-alerts.json=./builds/dynamic-test/testdata/behavior/falco-alerts.json \
  --dry-run=client -o yaml | oc apply -f -
oc create configmap fixture-dynamic-abnormal-resources -n "${NS_MODEL_EVAL}" \
  --from-file=kepler-samples.json=./builds/dynamic-test/testdata/abnormal-resources/kepler-samples.json \
  --dry-run=client -o yaml | oc apply -f -
oc create configmap fixture-dynamic-basic-inference -n "${NS_MODEL_EVAL}" \
  --from-file=README.txt=./builds/dynamic-test/testdata/basic-inference/README.txt \
  --dry-run=client -o yaml | oc apply -f -
oc apply -k ./overlays/07-tekton-tasks/ -n "${NS_MODEL_EVAL}"
oc create -f ./instances/tekton-tasks/dynamic-scan-unit-taskruns.yaml -n "${NS_MODEL_EVAL}"
oc wait --for=condition=Succeeded taskrun -l test=dynamic-scan-unit -n "${NS_MODEL_EVAL}" --timeout=600s
oc get taskrun -l test=dynamic-scan-unit -n "${NS_MODEL_EVAL}"
# Merge after subtasks (shared RWO PVC). Full file also has later-stage merges — apply those after each stage.

#
# Unit-test capability-eval TaskRuns (quality, performance-cost, stability-check, anomaly-bias-detection):
# Local (no cluster): bash builds/capability-eval/scripts/run-unit-tests.sh
oc create configmap fixture-capability-quality -n "${NS_MODEL_EVAL}" \
  --from-file=quality-scores.json=./builds/capability-eval/testdata/quality/quality-scores.json \
  --dry-run=client -o yaml | oc apply -f -
oc create configmap fixture-capability-performance-cost -n "${NS_MODEL_EVAL}" \
  --from-file=perf-metrics.json=./builds/capability-eval/testdata/performance-cost/perf-metrics.json \
  --dry-run=client -o yaml | oc apply -f -
oc create configmap fixture-capability-stability -n "${NS_MODEL_EVAL}" \
  --from-file=latency-samples.json=./builds/capability-eval/testdata/stability-check/latency-samples.json \
  --dry-run=client -o yaml | oc apply -f -
oc create configmap fixture-capability-anomaly-bias -n "${NS_MODEL_EVAL}" \
  --from-file=baseline-delta.json=./builds/capability-eval/testdata/anomaly-bias/baseline-delta.json \
  --dry-run=client -o yaml | oc apply -f -
oc apply -k ./overlays/07-tekton-tasks/ -n "${NS_MODEL_EVAL}"
oc delete task capability-eval -n "${NS_MODEL_EVAL}" --ignore-not-found
oc create -f ./instances/tekton-tasks/capability-eval-unit-taskruns.yaml -n "${NS_MODEL_EVAL}"
oc wait --for=condition=Succeeded taskrun -l test=capability-eval-unit -n "${NS_MODEL_EVAL}" --timeout=600s
oc get taskrun -l test=capability-eval-unit -n "${NS_MODEL_EVAL}"
#
# Unit-test adversarial-test TaskRuns (prompt-injection, jailbreak-guardrail-bypass, harmful-content-bias):
# Local (no cluster): bash builds/adversarial-test/scripts/run-unit-tests.sh
oc create configmap fixture-adversarial-prompt-injection -n "${NS_MODEL_EVAL}" \
  --from-file=injection-probes.json=./builds/adversarial-test/testdata/prompt-injection/injection-probes.json \
  --dry-run=client -o yaml | oc apply -f -
oc create configmap fixture-adversarial-jailbreak -n "${NS_MODEL_EVAL}" \
  --from-file=jailbreak-probes.json=./builds/adversarial-test/testdata/jailbreak-guardrail-bypass/jailbreak-probes.json \
  --dry-run=client -o yaml | oc apply -f -
oc create configmap fixture-adversarial-harmful-content-bias -n "${NS_MODEL_EVAL}" \
  --from-file=harmful-bias-probes.json=./builds/adversarial-test/testdata/harmful-content-bias/harmful-bias-probes.json \
  --dry-run=client -o yaml | oc apply -f -
oc apply -k ./overlays/07-tekton-tasks/ -n "${NS_MODEL_EVAL}"
oc delete task red-team -n "${NS_MODEL_EVAL}" --ignore-not-found
oc create -f ./instances/tekton-tasks/adversarial-test-unit-taskruns.yaml -n "${NS_MODEL_EVAL}"
oc wait --for=condition=Succeeded taskrun -l test=adversarial-test-unit -n "${NS_MODEL_EVAL}" --timeout=600s
oc get taskrun -l test=adversarial-test-unit -n "${NS_MODEL_EVAL}"
# Scan JSON is uploaded to s3://models-eval/unit-test/unit1/scan-result/
# (static-*.json, dynamic-*.json, capability-*.json, adversarial-*.json, score.json).
# PipelineRun scan JSON uses s3://models-eval/<model-id>/<version>/scan-result/.


# List unit-test JSON from MinIO (requires mc + minio-s3 secret):
# oc run cat-unit-results --rm -i --restart=Never -n "${NS_MODEL_EVAL}" \
#   --image=image-registry.openshift-image-registry.svc:5000/build-image/ai-security-publish:latest \
#   --overrides='...'  # source minio-s3 and: mc ls pipeline/models-eval/unit-test/unit1/scan-result/
#



# Full pipeline:
oc create -f ./instances/tekton-pipeline/pipelinerun-example.yaml -n "${NS_MODEL_EVAL}"
#
# After pass — update GitOps manifest from publish results:
# instances/model-test/llm-models/qwen3-8b-fp8-verified.yaml
oc apply -k ./overlays/16-test-serving/ -n "${NS_MODEL_TEST}"
#
# Watch:
oc get pipelinerun -n "${NS_MODEL_EVAL}" -w

# =============================================================================
# Phase 11: RHOAI platform (DSC + dashboard + Model Registry)
# =============================================================================
# Edit instances/model-registry/postgres-secret.yaml before apply.
oc apply -k ./overlays/11-rhoai/
oc wait --for=jsonpath='{.status.phase}'=Ready dscinitialization/default-dsci --timeout=600s
oc wait --for=jsonpath='{.status.phase}'=Ready datasciencecluster/default-dsc --timeout=600s
oc wait --for=condition=Established crd/odhdashboardconfigs.opendatahub.io --timeout=600s
oc wait --for=condition=Established crd/modelregistries.modelregistry.opendatahub.io --timeout=600s
oc apply -k ./overlays/12-rhoai-dashboard/
oc wait --for=condition=Available deployment/model-registry-db -n rhoai-model-registries --timeout=300s
oc wait --for=condition=Available modelregistry/model-registry -n rhoai-model-registries --timeout=600s
oc get modelregistry -n rhoai-model-registries

# =============================================================================
# Phase 12: Inference gateway + TLS
# =============================================================================
# Edit instances/gateway/gateway.yaml (hostname) and tlspolicy.yaml (issuer), then:
oc apply -k ./overlays/13-gateway/
oc get certificate -n openshift-ingress

# =============================================================================
# Phase 13: Authorino
# =============================================================================
oc annotate svc/authorino-authorino-authorization \
  service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert \
  -n kuadrant-system --overwrite || true
oc apply -k ./overlays/14-authorino/

# =============================================================================
# Phase 14: GPU hardware profile
# =============================================================================
oc apply -k ./overlays/15-hardware-profile/
# 
# Patch gateway to allow model-test routes (included in instances/gateway/gateway.yaml by default):
# Only needed if you removed model-test from gateway.yaml or use additional namespaces

# =============================================================================
# Phase 15: Test serving (verified model — registry-driven)
# =============================================================================
# Update instances/model-test/llm-models/qwen3-8b-fp8-verified.yaml
# (s3 URI + model-version = last five chars of PipelineRun name), then:
oc apply -k ./overlays/16-test-serving/ -n "${NS_MODEL_TEST}"
oc wait --for=condition=Ready llminferenceservice/qwen3-8b-fp8 -n "${NS_MODEL_TEST}" --timeout=900s
#
# Smoke test:
GATEWAY_HOST=$(oc get gateway openshift-ai-inference -n openshift-ingress \
  -o jsonpath='{.spec.listeners[0].hostname}')
TOKEN="$(oc create token test-user -n "${NS_MODEL_TEST}")"
curl -sS "https://${GATEWAY_HOST}/${NS_MODEL_TEST}/qwen3-8b-fp8/v1/models" \
  -H "Authorization: Bearer ${TOKEN}" | jq .

# =============================================================================
# Phase 16: GitOps promotion to model-test
# Promotion to model-prod is a later manual process (not this Application).
# =============================================================================
oc apply -k ./overlays/17-gitops/
oc get application model-test-verified-models -n openshift-gitops

# =============================================================================
# Cleanup (reverse order) — uncomment only when tearing down
# =============================================================================
# oc delete -k ./overlays/17-gitops/
# oc delete -k ./overlays/16-test-serving/ -n "${NS_MODEL_TEST}"
# oc delete -k ./overlays/15-hardware-profile/
# oc delete -k ./overlays/14-authorino/
# oc delete -k ./overlays/13-gateway/
# oc delete -k ./overlays/12-rhoai-dashboard/
# oc delete -k ./overlays/11-rhoai/
# oc delete -k ./overlays/10-tekton-chains/
# oc delete -k ./overlays/09-tekton-triggers/ -n "${NS_MODEL_EVAL}"
# oc delete -k ./overlays/08-tekton-pipeline/ -n "${NS_MODEL_EVAL}"
# oc delete -k ./overlays/07-tekton-tasks/ -n "${NS_MODEL_EVAL}"
# oc delete -k ./overlays/06-builds/ -n "${NS_BUILD_IMAGE}"
# oc delete -k ./instances/minio/ -n "${NS_MINIO}"
# oc delete -k ./instances/pipeline-rbac/ -n "${NS_MODEL_EVAL}"
# oc delete -k ./instances/model-test/ -n "${NS_MODEL_TEST}"
# oc delete -k ./instances/model-eval/ -n "${NS_MODEL_EVAL}"
# oc delete -k ./instances/model-ingress/ -n "${NS_MODEL_INGRESS}"
# oc delete -k ./overlays/03-operator-instances/
# oc delete -k ./overlays/02-operators/
# oc delete -k ./overlays/01-gpu-instances/
# oc delete -k ./overlays/00-gpu-operators/
