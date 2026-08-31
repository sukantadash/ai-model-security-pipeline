# AI Model Security Pipeline — manual deployment runbook
# Design: README.md, docs/architecture.md, docs/pipeline.md, IMPLEMENTATION-PLAN.md
# Overlays: overlays/00-gpu-operators … 17-gitops
#
# Prerequisites:
#   oc login ...
#   GPU nodes: infra/prereqs/ocp-gpu-setup/README.md
#   Quay org + secrets configured (quay-secret.yaml from template)
#   Hugging Face token for gated models (model-ingress)
#   git-url in pipelinerun-example.yaml must be a cloneable HTTPS repo with
#   instances/model-sandbox/LLMInferenceService.yaml pushed
#
# Run phase-by-phase: copy/paste each phase block into your shell (do not run bash script.sh end-to-end).

cd "$(dirname "$0")"

# Platform namespaces — override via environment before running commands below.
export NS_MODEL_INGRESS="${NS_MODEL_INGRESS:-model-ingress}"
export NS_MODEL_EVAL="${NS_MODEL_EVAL:-model-eval}"
export NS_MODEL_TEST="${NS_MODEL_TEST:-model-test}"
export NS_MODEL_SANDBOX="${NS_MODEL_SANDBOX:-model-sandbox}"
export NS_BUILD_IMAGE="${NS_BUILD_IMAGE:-build-image}"
export NS_MINIO="${NS_MINIO:-minio-system}"

# =============================================================================
# Phase 0: Cluster GPU prerequisites
# Overlay: 00-gpu-operators, 01-gpu-instances
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
# Phase 1: Operators (Pipelines, GitOps, Service Mesh, RHOAI, Kata, …)
# Overlay: 02-operators
# =============================================================================
oc apply -k ./overlays/02-operators/
#
# Wait for CSV Succeeded (Sandboxed Containers uses a dedicated namespace):
oc get csv -A | grep -E 'pipelines|gitops|rhods|servicemesh|kuadrant|sandboxed'
oc get csv -n openshift-sandboxed-containers-operator
# RuntimeClass kata appears after KataConfig (Phase 3).
#
# Manual: approve any Manual InstallPlans if required
oc get installplan -A
# oc patch installplan <name> -n <ns> --type merge -p '{"spec":{"approved":true}}'

# =============================================================================
# Phase 2: Zones — namespaces, NetworkPolicies, pipeline RBAC
# Overlay: 04-zones (eval/sandbox/test + pipeline-rbac). Design table lists this
# as Phase 3; apply before overlay 03 so namespaces exist before KataConfig reboots.
# model-ingress: pass namespace on the oc command (kustomization has no namespace:).
# model-sandbox persists (pipeline never creates/deletes the namespace).
# =============================================================================
oc apply -k ./instances/model-ingress/ -n "${NS_MODEL_INGRESS}"
oc apply -k ./overlays/04-zones/
#
# Verify:
oc get ns "${NS_MODEL_INGRESS}" "${NS_MODEL_EVAL}" "${NS_MODEL_SANDBOX}" "${NS_MODEL_TEST}"
oc get sa model-eval-pipeline -n "${NS_MODEL_EVAL}"
oc get networkpolicy -n "${NS_MODEL_EVAL}" | grep -E 'serve-llm|pipeline-oc' || true
oc get networkpolicy,role,rolebinding -n "${NS_MODEL_SANDBOX}"
oc get role,rolebinding -n "${NS_MODEL_TEST}" | grep model-eval-pipeline || true

# =============================================================================
# Phase 3: Operator instances (Tekton Chains, Service Mesh, KataConfig, …)
# Overlay: 03-operator-instances
# =============================================================================
oc apply -k ./overlays/03-operator-instances/
#
# KataConfig triggers worker node reboots (10–60+ min). Verify before Tekton pipeline runs:
oc describe kataconfig cluster-kataconfig
oc get runtimeclass kata

# =============================================================================
# Phase 4: MinIO + eval workspace PVC + zone secrets
# Overlay: 05-storage
# =============================================================================
# Edit instances/minio/secret.yaml (root password), then:
oc apply -k ./overlays/05-storage/
# MinIO reads minio-root only at pod start — restart after any password change.
oc rollout restart deployment/minio -n "${NS_MINIO}"
oc rollout status deployment/minio -n "${NS_MINIO}" --timeout=300s
oc wait --for=condition=Available deployment/minio -n "${NS_MINIO}" --timeout=600s
oc wait --for=condition=complete job/minio-bucket-init -n "${NS_MINIO}" --timeout=300s
oc get route minio-api minio-console -n "${NS_MINIO}"
# Overlay 05 creates eval-workspace in model-eval. Ingress/test PVCs are per-zone:
oc apply -f ./instances/storage/ingress-models-pvc.yaml -n "${NS_MODEL_INGRESS}"
oc apply -f ./instances/storage/verified-models-pvc.yaml -n "${NS_MODEL_TEST}"
# Restore the committed placeholder if you edited instances/minio/secret.yaml:
#   git checkout -- instances/minio/secret.yaml

#
# Secrets (see instances/secrets/README.md):
# cp minio-s3-secret.yaml.template minio-s3-secret.yaml   # edit credentials first
for ns in "${NS_MODEL_INGRESS}" "${NS_MODEL_EVAL}" "${NS_MODEL_SANDBOX}" "${NS_MODEL_TEST}"; do
  oc apply -f minio-s3-secret.yaml -n "${ns}"
done
for ns in "${NS_MODEL_INGRESS}" "${NS_MODEL_EVAL}" "${NS_MODEL_SANDBOX}" "${NS_MODEL_TEST}"; do
  oc get secret minio-s3 -n "${ns}"
done
# Optional private git clone (serve-llm-start / publish-artifact):
# oc create secret generic git-auth -n "${NS_MODEL_EVAL}" --from-literal=token=<github-pat>
# cp quay-secret.yaml.template quay-secret.yaml             # edit credentials first
oc apply -f quay-secret.yaml -n "${NS_BUILD_IMAGE}"
oc secrets link builder sudash-modelpipeline-pull-secret -n "${NS_BUILD_IMAGE}"
oc apply -f quay-secret.yaml -n "${NS_MODEL_INGRESS}"
oc apply -f quay-secret.yaml -n "${NS_MODEL_EVAL}"
oc apply -f quay-secret.yaml -n "${NS_MODEL_TEST}"
#
# Hugging Face token (ingress only, gated models) — replace <your-token>:
# oc create secret generic hf-token -n "${NS_MODEL_INGRESS}" \
#   --from-literal=HF_TOKEN=<your-token>

# =============================================================================
# Phase 5: Build custom scanner images
# Overlay: 06-builds  Images: docs/pipeline.md "Scanner images"
# =============================================================================
oc apply -k ./overlays/06-builds/ -n "${NS_BUILD_IMAGE}"
oc apply -f quay-secret.yaml -n "${NS_BUILD_IMAGE}"
oc secrets link builder sudash-modelpipeline-pull-secret -n "${NS_BUILD_IMAGE}"

for bc in model-fetch static-scan dynamic-test dynamic-gpu capability-eval adversarial-test score-gate publish; do
  oc start-build "ai-security-${bc}" --from-dir="builds/${bc}" --follow -n "${NS_BUILD_IMAGE}"
done

oc get istag -n "${NS_BUILD_IMAGE}" | grep ai-security

# Cross-namespace pull (ingress Job + eval Tekton + sandbox KServe):
for ns in "${NS_MODEL_INGRESS}" "${NS_MODEL_EVAL}" "${NS_MODEL_SANDBOX}"; do
  oc policy add-role-to-group system:image-puller "system:serviceaccounts:${ns}" -n "${NS_BUILD_IMAGE}"
done
# After script changes under builds/, rebuild that image before the next PipelineRun:
#   oc start-build ai-security-dynamic-test --from-dir=builds/dynamic-test --follow -n "${NS_BUILD_IMAGE}"

# =============================================================================
# Phase 6: Tekton Tasks
# Overlay: 07-tekton-tasks  DAG: docs/pipeline.md
# =============================================================================
oc apply -k ./overlays/07-tekton-tasks/ -n "${NS_MODEL_EVAL}"

# =============================================================================
# Phase 7: Tekton Pipeline
# Overlay: 08-tekton-pipeline
# =============================================================================
oc apply -k ./overlays/08-tekton-pipeline/ -n "${NS_MODEL_EVAL}"

# =============================================================================
# Phase 8: Tekton Triggers
# Overlay: 09-tekton-triggers
# =============================================================================
oc apply -k ./overlays/09-tekton-triggers/ -n "${NS_MODEL_EVAL}"
oc get eventlistener,route -n "${NS_MODEL_EVAL}"
# Optional webhook test:
#   curl -X POST "https://$(oc get route el-model-security-listener -n "${NS_MODEL_EVAL}" -o jsonpath='{.spec.host}')" \
#     -H 'Content-Type: application/json' \
#     -d '{"model_id":"redhatai-qwen3-8b-fp8-dynamic"}'

# =============================================================================
# Phase 9: Tekton Chains (SLSA / Cosign signing)
# Overlay: 10-tekton-chains
# =============================================================================
oc apply -k ./overlays/10-tekton-chains/

# =============================================================================
# Phase 10: Fetch + unit TaskRuns (fixtures; no live vLLM)
# Live PipelineRun (serve-llm + publish to Model Registry) is after Phase 11.
# =============================================================================
# Local (no cluster) — run these first after code changes:
#   pip3 install pyyaml
#   python3 builds/publish/scripts/test_patch_llmis.py
#   python3 builds/dynamic-test/scripts/test_isolated_inspect.py
#   bash builds/dynamic-test/scripts/run-unit-tests.sh
#   bash builds/capability-eval/scripts/run-unit-tests.sh
#   bash builds/adversarial-test/scripts/run-unit-tests.sh
#
oc apply -f ./instances/model-ingress-fetch/model-fetch-job.yaml -n "${NS_MODEL_INGRESS}"
oc wait --for=condition=complete job/model-fetch -n "${NS_MODEL_INGRESS}" --timeout=7200s

# Re-apply Tasks if you changed instances/tekton-tasks/ since Phase 6:
oc apply -k ./overlays/07-tekton-tasks/ -n "${NS_MODEL_EVAL}"
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
oc create -f ./instances/tekton-tasks/dynamic-scan-unit-taskruns.yaml -n "${NS_MODEL_EVAL}"
oc wait --for=condition=Succeeded taskrun -l test=dynamic-scan-unit -n "${NS_MODEL_EVAL}" --timeout=600s
oc get taskrun -l test=dynamic-scan-unit -n "${NS_MODEL_EVAL}"
#
# Unit-test capability-eval TaskRuns (quality, performance-cost, stability-check, anomaly-bias-detection):
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
oc create -f ./instances/tekton-tasks/capability-eval-unit-taskruns.yaml -n "${NS_MODEL_EVAL}"
oc wait --for=condition=Succeeded taskrun -l test=capability-eval-unit -n "${NS_MODEL_EVAL}" --timeout=600s
oc get taskrun -l test=capability-eval-unit -n "${NS_MODEL_EVAL}"
#
# Unit-test adversarial-test TaskRuns (prompt-injection, jailbreak-guardrail-bypass, harmful-content-bias):
oc create configmap fixture-adversarial-prompt-injection -n "${NS_MODEL_EVAL}" \
  --from-file=injection-probes.json=./builds/adversarial-test/testdata/prompt-injection/injection-probes.json \
  --dry-run=client -o yaml | oc apply -f -
oc create configmap fixture-adversarial-jailbreak -n "${NS_MODEL_EVAL}" \
  --from-file=jailbreak-probes.json=./builds/adversarial-test/testdata/jailbreak-guardrail-bypass/jailbreak-probes.json \
  --dry-run=client -o yaml | oc apply -f -
oc create configmap fixture-adversarial-harmful-content-bias -n "${NS_MODEL_EVAL}" \
  --from-file=harmful-bias-probes.json=./builds/adversarial-test/testdata/harmful-content-bias/harmful-bias-probes.json \
  --dry-run=client -o yaml | oc apply -f -
oc create -f ./instances/tekton-tasks/adversarial-test-unit-taskruns.yaml -n "${NS_MODEL_EVAL}"
oc wait --for=condition=Succeeded taskrun -l test=adversarial-test-unit -n "${NS_MODEL_EVAL}" --timeout=600s
oc get taskrun -l test=adversarial-test-unit -n "${NS_MODEL_EVAL}"
#
# Merge + score-gate units (concat S3 JSON from the unit-test prefix, then score):
oc create -f ./instances/tekton-tasks/merge-and-gate-unit-taskruns.yaml -n "${NS_MODEL_EVAL}"
oc wait --for=condition=Succeeded taskrun -l test=static-scan-merge-unit -n "${NS_MODEL_EVAL}" --timeout=300s
oc wait --for=condition=Succeeded taskrun -l test=dynamic-scan-merge-unit -n "${NS_MODEL_EVAL}" --timeout=300s
oc wait --for=condition=Succeeded taskrun -l test=capability-eval-merge-unit -n "${NS_MODEL_EVAL}" --timeout=300s
oc wait --for=condition=Succeeded taskrun -l test=adversarial-test-merge-unit -n "${NS_MODEL_EVAL}" --timeout=300s
oc wait --for=condition=Succeeded taskrun -l test=score-gate-unit -n "${NS_MODEL_EVAL}" --timeout=300s
# Unit JSON: s3://models-eval/unit-test/unit1/scan-result/
# PipelineRun JSON: s3://models-eval/<model-id>/<version>/scan-result/

# =============================================================================
# Phase 11: RHOAI platform (DSC + dashboard + Model Registry)
# Overlay: 11-rhoai, 12-rhoai-dashboard
# Required before publish-artifact can register the model.
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

# Live pipeline (docs/pipeline.md DAG). Edit git-url in pipelinerun-example.yaml
# to a reachable HTTPS repo; push instances/model-sandbox/LLMInferenceService.yaml.
# Confirm sandbox is empty of a leftover eval-* CR, then:
oc get llminferenceservice -n "${NS_MODEL_SANDBOX}"
oc get secret minio-s3 -n "${NS_MODEL_SANDBOX}"
oc get pipeline.tekton.dev model-security-pipeline -n "${NS_MODEL_EVAL}" \
  -o jsonpath='{.spec.params[?(@.name=="git-url")].default}{"\n"}'
oc create -f ./instances/tekton-pipeline/pipelinerun-example.yaml -n "${NS_MODEL_EVAL}"
oc get pipelinerun -n "${NS_MODEL_EVAL}" -w
#
# After serve-llm-start: CR is in model-sandbox (not model-eval):
#   oc get llminferenceservice,svc,pod -n "${NS_MODEL_SANDBOX}"
# After finally: CR deleted, namespace remains:
#   oc get ns "${NS_MODEL_SANDBOX}"
#   oc get llminferenceservice -n "${NS_MODEL_SANDBOX}"
# Auto-pass: publish-artifact copies weights to models-verified, registers Model
# Registry, and oc apply's the patched LLMInferenceService in model-test.

# =============================================================================
# Phase 12: Inference gateway + TLS
# Overlay: 13-gateway
# =============================================================================
# Lab/demo cluster FQDNs must not be committed. Set hostname from this cluster:
#   APPS_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
#   echo "inference-gateway.${APPS_DOMAIN}"
# Edit instances/gateway/gateway.yaml — replace REPLACE_WITH_CLUSTER_APPS_DOMAIN:
#   hostname: inference-gateway.${APPS_DOMAIN}
# Edit instances/gateway/tlspolicy.yaml issuerRef.name (oc get clusterissuer).
# Optional GuideLLM — same domain in instances/guidellm-benchmark/guidellm-benchmark-job.yaml:
#   GUIDELLM_TARGET=https://inference-gateway.${APPS_DOMAIN}/${NS_MODEL_TEST}/qwen3-8b-fp8
oc apply -k ./overlays/13-gateway/
oc get certificate -n openshift-ingress

# =============================================================================
# Phase 13: Authorino
# Overlay: 14-authorino
# =============================================================================
oc annotate svc/authorino-authorino-authorization \
  service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert \
  -n kuadrant-system --overwrite || true
oc apply -k ./overlays/14-authorino/

# =============================================================================
# Phase 14: GPU hardware profile
# Overlay: 15-hardware-profile
# =============================================================================
oc apply -k ./overlays/15-hardware-profile/
# Gateway already allows model-test routes (instances/gateway/gateway.yaml).
# Patch only if you removed model-test or add more namespaces.

# =============================================================================
# Phase 15: Test serving (verified model)
# Overlay: 16-test-serving (serving-rbac + optional LLMInferenceService catch-up)
# publish-artifact already applies the patched CR in model-test on auto-pass.
# =============================================================================
oc apply -k ./instances/model-test/serving-rbac/ -n "${NS_MODEL_TEST}"
# oc apply -k ./overlays/16-test-serving/ -n "${NS_MODEL_TEST}"
oc get llminferenceservice -n "${NS_MODEL_TEST}"
# oc wait --for=condition=Ready llminferenceservice -n "${NS_MODEL_TEST}" --timeout=900s
#
# Smoke test:
GATEWAY_HOST=$(oc get gateway openshift-ai-inference -n openshift-ingress \
  -o jsonpath='{.spec.listeners[0].hostname}')
TOKEN="$(oc create token test-user -n "${NS_MODEL_TEST}")"
curl -sS "https://${GATEWAY_HOST}/${NS_MODEL_TEST}/qwen3-8b-fp8/v1/models" \
  -H "Authorization: Bearer ${TOKEN}" | jq .

# =============================================================================
# Phase 16: GitOps promotion to model-test
# Overlay: 17-gitops  Promotion to model-prod is a later manual process.
# =============================================================================
# Edit instances/gitops/application-model-test.yaml spec.source.repoURL / targetRevision.
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
# oc delete -k ./overlays/05-storage/
# oc delete -k ./overlays/04-zones/
# oc delete -k ./instances/model-ingress/ -n "${NS_MODEL_INGRESS}"
# oc delete -k ./overlays/03-operator-instances/
# oc delete -k ./overlays/02-operators/
# oc delete -k ./overlays/01-gpu-instances/
# oc delete -k ./overlays/00-gpu-operators/
