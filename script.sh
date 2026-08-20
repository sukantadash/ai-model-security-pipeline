# AI Model Security Pipeline — manual deployment runbook
# Reference: HIGH-LEVEL-DESIGN.md, IMPLEMENTATION-PLAN.md
#
# Prerequisites:
#   oc login ...
#   GPU nodes: infra/prereqs/ocp-gpu-setup/README.md
#   Quay org + secrets configured (quay-secret.yaml from template)
#   Hugging Face token for model-ingress

cd "$(dirname "$0")"

# =============================================================================
# Phase 0: Cluster GPU prerequisites
# =============================================================================
# Step 1 — MachineSet (see infra/prereqs/ocp-gpu-setup/README.md):
#   cd infra/prereqs/ocp-gpu-setup && ./machine-set/gpu-machineset.sh
#
# Steps 2–4 — from repo root:
#   oc apply -k ./overlays/00-gpu-operators/
#   oc wait --for=condition=Available subscription/nfd -n openshift-nfd --timeout=600s
#   oc wait --for=condition=Available subscription/gpu-operator-certified -n nvidia-gpu-operator --timeout=600s
#   oc apply -k ./overlays/01-gpu-instances/
#
# Verify:
#   oc get nodes -l nvidia.com/gpu.present=true
#   oc get clusterpolicy cluster-policy -n nvidia-gpu-operator

# =============================================================================
# Phase 1: Operators (Pipelines, GitOps, Service Mesh, RHOAI, …)
# =============================================================================
# oc apply -k ./overlays/02-operators/
#
# Wait for subscriptions (includes Sandboxed Containers for Kata):
#   oc get csv -A | grep -E 'pipelines|gitops|rhods|servicemesh|kuadrant|sandboxed'
#   oc get runtimeclass kata   # after Sandboxed Containers operator is ready
#
# Manual: approve any Manual InstallPlans if required
#   oc get installplan -A
#   oc patch installplan <name> -n <ns> --type merge -p '{"spec":{"approved":true}}'

# =============================================================================
# Phase 2: Operator instances (Tekton Chains, pipeline RBAC, Service Mesh, …)
# =============================================================================
# oc apply -k ./overlays/03-operator-instances/

# =============================================================================
# Phase 3: Three zones — namespaces, NetworkPolicies
# =============================================================================
# oc apply -k ./overlays/04-zones/
#
# Verify:
#   oc get ns model-ingress model-eval model-prod

# =============================================================================
# Phase 4: MinIO + eval workspace PVC
# =============================================================================
# Edit instances/minio/secret.yaml (root password), then:
# oc apply -k ./overlays/05-storage/
# oc wait --for=condition=Available deployment/minio -n minio-system --timeout=600s
# oc wait --for=condition=complete job/minio-bucket-init -n minio-system --timeout=300s
#
# Secrets (see instances/secrets/README.md):
#   cp minio-s3-secret.yaml.template minio-s3-secret.yaml   # edit
#   for ns in model-ingress model-eval model-prod; do
#     oc apply -f minio-s3-secret.yaml -n "${ns}"
#   done
#   cp quay-secret.yaml.template quay-secret.yaml             # scanner images only
#   oc apply -f quay-secret.yaml -n model-ingress
#   oc apply -f quay-secret.yaml -n model-eval
#   oc secrets link builder sudash-modelpipeline-pull-secret -n model-eval
#
# Hugging Face token (ingress only):
#   oc create secret generic hf-token -n model-ingress \
#     --from-literal=HF_TOKEN=<your-token>

# =============================================================================
# Phase 5: Build custom scanner images
# =============================================================================
# oc apply -k ./overlays/06-builds/
#
# Build each image (Quay hosts scanner images only):
#   oc start-build ai-security-model-fetch --follow -n model-eval
#   oc start-build ai-security-static-scan --follow -n model-eval
#   oc start-build ai-security-dynamic-test --follow -n model-eval
#   oc start-build ai-security-dynamic-gpu --follow -n model-eval
#   oc start-build ai-security-capability-eval --follow -n model-eval
#   oc start-build ai-security-red-team --follow -n model-eval
#   oc start-build ai-security-score-gate --follow -n model-eval
#   oc start-build ai-security-publish --follow -n model-eval

# =============================================================================
# Phase 6: Tekton Tasks
# =============================================================================
# oc apply -k ./overlays/07-tekton-tasks/

# =============================================================================
# Phase 7: Tekton Pipeline
# =============================================================================
# oc apply -k ./overlays/08-tekton-pipeline/

# =============================================================================
# Phase 8: Tekton Triggers
# =============================================================================
# oc apply -k ./overlays/09-tekton-triggers/

# =============================================================================
# Phase 9: Tekton Chains (SLSA / Cosign signing)
# =============================================================================
# oc apply -k ./overlays/10-tekton-chains/

# =============================================================================
# Phase 10: Test — HF download → PipelineRun (RedHatAI/Qwen3-8B-FP8-dynamic)
# =============================================================================
#   oc apply -f ./instances/model-ingress-fetch/model-fetch-job.yaml
#   oc wait --for=condition=complete job/model-fetch -n model-ingress --timeout=7200s
#   oc create -f ./instances/tekton-pipeline/pipelinerun-example.yaml
#
# After pass — update GitOps manifest from publish results:
#   # instances/model-prod/llm-models/qwen3-8b-fp8-verified.yaml
#   oc apply -k ./overlays/16-production-serving/   # or overlay 17 GitOps sync
#
# Watch:
#   oc get pipelinerun -n model-eval -w

# =============================================================================
# Phase 11: RHOAI platform (DSC + dashboard)
# =============================================================================
# oc apply -k ./overlays/11-rhoai/
# oc wait --for=jsonpath='{.status.phase}'=Ready dscinitialization/default-dsci --timeout=600s
# oc wait --for=jsonpath='{.status.phase}'=Ready datasciencecluster/default-dsc --timeout=600s
# oc wait --for=condition=Established crd/odhdashboardconfigs.opendatahub.io --timeout=600s
# oc apply -k ./overlays/12-rhoai-dashboard/

# =============================================================================
# Phase 12: Inference gateway + TLS
# =============================================================================
# Edit instances/gateway/gateway.yaml (hostname) and tlspolicy.yaml (issuer), then:
# oc apply -k ./overlays/13-gateway/
# oc get certificate -n openshift-ingress

# =============================================================================
# Phase 13: Authorino
# =============================================================================
# oc annotate svc/authorino-authorino-authorization \
#   service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert \
#   -n kuadrant-system --overwrite || true
# oc apply -k ./overlays/14-authorino/

# =============================================================================
# Phase 14: GPU hardware profile
# =============================================================================
# oc apply -k ./overlays/15-hardware-profile/
#
# Patch gateway to allow model-prod routes (included in instances/gateway/gateway.yaml by default):
#   # Only needed if you removed model-prod from gateway.yaml or use additional namespaces

# =============================================================================
# Phase 15: Production serving (verified model — registry-driven)
# =============================================================================
# Update instances/model-prod/llm-models/qwen3-8b-fp8-verified.yaml
# (s3 URI + model-version from publish-artifact), then:
# oc apply -k ./overlays/16-production-serving/
# oc wait --for=condition=Ready llminferenceservice/qwen3-8b-fp8 -n model-prod --timeout=900s
#
# Smoke test:
#   GATEWAY_HOST=$(oc get gateway openshift-ai-inference -n openshift-ingress \
#     -o jsonpath='{.spec.listeners[0].hostname}')
#   TOKEN="$(oc create token test-user -n model-prod)"
#   curl -sS "https://${GATEWAY_HOST}/model-prod/qwen3-8b-fp8/v1/models" \
#     -H "Authorization: Bearer ${TOKEN}" | jq .

# =============================================================================
# Phase 16: GitOps promotion
# =============================================================================
# oc apply -k ./overlays/17-gitops/
# oc get application model-prod-verified-models -n openshift-gitops

# =============================================================================
# Cleanup (reverse order)
# =============================================================================
# oc delete -k ./overlays/17-gitops/
# oc delete -k ./overlays/16-production-serving/
# oc delete -k ./overlays/15-hardware-profile/
# oc delete -k ./overlays/14-authorino/
# oc delete -k ./overlays/13-gateway/
# oc delete -k ./overlays/12-rhoai-dashboard/
# oc delete -k ./overlays/11-rhoai/
# oc delete -k ./overlays/10-tekton-chains/
# oc delete -k ./overlays/09-tekton-triggers/
# oc delete -k ./overlays/08-tekton-pipeline/
# oc delete -k ./overlays/07-tekton-tasks/
# oc delete -k ./overlays/06-builds/
# oc delete -k ./overlays/05-storage/
# oc delete -k ./overlays/04-zones/
# oc delete -k ./overlays/03-operator-instances/
# oc delete -k ./overlays/02-operators/
# oc delete -k ./overlays/01-gpu-instances/
# oc delete -k ./overlays/00-gpu-operators/
