# AI Model Security Platform — Implementation Plan

**Based on:** [HIGH-LEVEL-DESIGN.md](./HIGH-LEVEL-DESIGN.md)  
**Deployment pattern:** rhoai3-style kustomize (`operators/`, `instances/`, `overlays/`) + manual `oc` runbook in [script.sh](./script.sh)  
**Last updated:** August 20, 2026

---

## 1. Goals

1. Deploy three zones on one OpenShift cluster: `model-ingress`, `model-eval`, `model-prod`.
2. Run a Tekton pipeline that validates Hugging Face model artifacts before production serving.
3. Build custom scanner/evaluator images under `builds/` and push to Quay.
4. Reuse root `operators/`, `instances/`, and `overlays/` for RHOAI production inference after models pass the pipeline.

---

## 2. Proposed Repository Layout

Single unified layout at repo root — security pipeline and RHOAI inference share `operators/`, `instances/`, and `overlays/`:

```text
ai-model-security-pipeline/
├── script.sh                       # manual step-by-step oc runbook
├── builds/                         # Tekton scanner image BuildConfigs
├── operators/                      # NFD, GPU, Pipelines, GitOps, Service Mesh, RHOAI, …
├── instances/                      # zones, Tekton, gateway, rhoai, model-prod, …
├── overlays/                       # 00-gpu-operators … 17-gitops (ordered apply)
├── infra/prereqs/ocp-gpu-setup/    # GPU MachineSet script only
└── quay-secret.yaml.template       # copy to quay-secret.yaml (gitignored)
```

**Component locations:**

| Component | Location | When |
|-----------|----------|------|
| GPU MachineSet | `infra/prereqs/ocp-gpu-setup/machine-set/` | Phase 0 step 1 |
| NFD + GPU Operator + CRs | `overlays/00-gpu-operators`, `01-gpu-instances` | Phase 0 steps 2–4 |
| Security pipeline | `overlays/02`–`10` | Phases 1–9 |
| RHOAI inference platform | `overlays/11`–`15` | Phases 11–14 |
| Verified model serving | `overlays/16-production-serving` | Phase 15 |
| GitOps promotion | `overlays/17-gitops` | Phase 16 |

---

## 3. External Systems Required

| System | Required? | Purpose |
|--------|-----------|---------|
| **OpenShift 4.14+ cluster** | Yes | Hosts all three zones |
| **GPU worker nodes** | Yes (capability + dynamic stages) | `infra/prereqs/ocp-gpu-setup/` |
| **Quay (or embedded registry)** | Yes | Container images + optional model artifact blobs |
| **Hugging Face Hub** | Yes | Source for untrusted model downloads (`hf://org/model`) |
| **OpenShift Pipelines** | Yes | Tekton orchestration in `model-eval` |
| **Tekton Chains** | Yes | SLSA provenance + Cosign signing |
| **OpenShift GitOps (Argo CD)** | Yes | Promote verified models to `model-prod` |
| **Object storage (ODF/S3/NOOBAA)** | Recommended | Large model weights (multi-GB); PVC alone is fragile |
| **Red Hat OpenShift AI (RHOAI)** | Recommended | KServe / LLMInferenceService in production zone |
| **Sandboxed Containers (Kata)** | Phase 2 | VM isolation for dynamic runtime testing |
| **Sigstore / Rekor** | Optional | External attestation storage (Chains can use internal OCP secrets) |
| **Vault or cloud KMS** | Optional | Tekton Chains signing keys |
| **Clair / Syft registry** | Optional | CVE scanning of dependency layers (can run in-cluster) |

### Network egress policy (by zone)

| Zone | Allowed egress |
|------|----------------|
| `model-ingress` | Hugging Face Hub only (for model download job) |
| `model-eval` | Internal cluster services + Quay; **no** public internet by default |
| `model-prod` | Quay, internal services; Hugging Face **denied** (models arrive signed) |

---

## 4. Storage Strategy

### 4.1 Where things live

| Asset | Store in | Namespace | Notes |
|-------|----------|-----------|-------|
| **Scanner container images** | **Quay** | cluster-wide pull | Built from `builds/` — scanner images only |
| **Untrusted HF model weights** | **MinIO** `models-ingress/` | cluster-wide S3 | e.g. `redhatai-qwen3-8b-fp8-dynamic/` |
| **Pipeline workspace / scan JSON** | PVC + MinIO `models-eval/` | `model-eval` | Tekton workspace PVC; results optionally archived |
| **Verified model artifacts** | **MinIO** `models-verified/` | via Model Registry | Promoted by `publish-artifact` |
| **Attestations (Cosign/SLSA)** | MinIO `attestations/` | `model-eval` | Tekton Chains + score JSON |
| **Production inference** | **RHOAI Model Registry** → MinIO URI | `model-prod` | Registry drives serving; GitOps syncs manifest |
| **Tekton / build logs** | OpenShift Pipelines | `model-eval` | Built-in logs |

MinIO deploys via overlay **`05-storage`** (`instances/minio/`). Zone credentials: `minio-s3-secret.yaml.template`.

### 4.2 Hugging Face download flow

```text
1. User submits: hf://RedHatAI/Qwen3-8B-FP8-dynamic
2. model-fetch Job (model-ingress) → s3://models-ingress/redhatai-qwen3-8b-fp8-dynamic/
3. Tekton Trigger (or manual PipelineRun)
4. fetch-artifact: mc mirror ingress → eval-workspace PVC
5. static → dynamic-probe (Kata) → dynamic-gpu-load (GPU) → capability → red-team → score-gate
6. publish-artifact: promote to models-verified/ + register RHOAI Model Registry
7. GitOps updates LLMInferenceService (registry annotations + s3:// URI)
```

### 4.3 Quay organization layout (scanner images only)

```text
quay.io/<org>/
├── ai-security-model-fetch:latest
├── ai-security-static-scan:latest
├── ai-security-dynamic-test:latest
├── ai-security-dynamic-gpu:latest
├── ai-security-capability-eval:latest
├── ai-security-red-team:latest
├── ai-security-score-gate:latest
└── ai-security-publish:latest
```

Verified model weights are **not** stored in Quay — use MinIO `models-verified/`.

---

## 5. Custom Images (`builds/`)

All images defined in [builds/build.yaml](./builds/build.yaml).

| Image | Base | Tools bundled | Used by Tekton Task |
|-------|------|---------------|-------------------|
| `ai-security-model-fetch` | `ubi9/python-312` | `huggingface_hub`, `magika` | fetch-artifact |
| `ai-security-static-scan` | `ubi9/python-312` | ModelAudit, Fickling, ClamAV, Syft | static-scan |
| `ai-security-dynamic-test` | `cuda` + vLLM | vLLM probe, syscall wrapper | dynamic-test (Kata RuntimeClass) |
| `ai-security-capability-eval` | `ubi9/python-312` + GPU | lm-eval-harness, DeepEval | capability-eval |
| `ai-security-red-team` | `ubi9/python-312` | Garak, Promptfoo, LLM Guard | red-team |
| `ai-security-score-gate` | `ubi9/python-312` | aggregation script | score-gate |

Build commands (after overlay `06-builds`):

```bash
oc apply -k ./overlays/06-builds/
oc start-build ai-security-static-scan --follow -n model-eval
# repeat for each image, or use a loop in script.sh
```

---

## 6. Overlay Deployment Phases

Run manually from repo root; see [script.sh](./script.sh) for exact commands.

| Phase | Overlay(s) | Purpose |
|-------|------------|---------|
| **0** | `00-gpu-operators`, `01-gpu-instances` | GPU MachineSet (script), NFD, NVIDIA GPU Operator |
| **1** | `02-operators` | Pipelines, GitOps, Service Mesh, RHOAI |
| **2** | `03-operator-instances` | Tekton Chains/RBAC, Service Mesh, Kuadrant, LWS |
| **3** | `04-zones` | Namespaces + NetworkPolicies |
| **4** | `05-storage` | PVCs, Quay/HF secrets (manual) |
| **5** | `06-builds` | ImageStreams + BuildConfigs |
| **6** | `07-tekton-tasks` | One Task per pipeline step |
| **7** | `08-tekton-pipeline` | Pipeline + score gate |
| **8** | `09-tekton-triggers` | EventListener on ingress upload |
| **9** | `10-tekton-chains` | SLSA signing policy |
| **10** | *(manual)* | HF download, eval copy, PipelineRun smoke test |
| **11** | `11-rhoai`, `12-rhoai-dashboard` | DataScienceCluster + dashboard |
| **12** | `13-gateway` | Inference gateway + TLS |
| **13** | `14-authorino` | Gateway authorization |
| **14** | `15-hardware-profile` | GPU hardware profile |
| **15** | `16-production-serving` | Verified LLMInferenceService in model-prod |
| **16** | `17-gitops` | Argo CD Application for model-prod |

---

## 7. Tekton Pipeline Tasks (instances/model-eval)

| Task | Input | Output | runAfter |
|------|-------|--------|----------|
| `fetch-artifact` | MinIO `models-ingress/<model-id>/` | eval workspace `/models/` | — |
| `static-scan` | model files | `static.json` | fetch-artifact (Kata) |
| `dynamic-probe` | model files | `dynamic-probe.json` | static-scan (Kata) |
| `dynamic-gpu-load` | model files + GPU | `dynamic-gpu.json` | dynamic-probe |
| `capability-eval` | model files + GPU | `capability.json` | dynamic-gpu-load |
| `red-team` | model / endpoint | `redteam.json` | capability-eval |
| `score-gate` | all `*.json` | pass/fail + `score.json` | red-team |
| `publish-artifact` | model + attestation | MinIO verified + MR register | score-gate (on success) |

Pipeline name: `model-security-pipeline` in namespace `model-eval`.

---

## 8. Integration with RHOAI Production Serving

After a model passes the pipeline:

1. Tekton `publish-artifact` promotes weights to MinIO `models-verified/<model-id>/<version>/`.
2. Same task registers the model in **RHOAI Model Registry** (`rhoai-model-registries`).
3. GitOps manifest `instances/model-prod/llm-models/qwen3-8b-fp8-verified.yaml` is updated with registry annotations + `s3://` URI (registry drives serving).
4. Argo CD syncs `LLMInferenceService` to `model-prod`; inference pulls from MinIO via registry metadata.

---

## 9. Implementation Order (Sprints)

### Sprint 1 — Foundation
- [ ] Scaffold `operators/`, `instances/`, `overlays/` directories
- [ ] Phase 0–3: GPU prereqs, operators, zones
- [ ] Phase 4: storage + secrets
- [ ] Verify namespaces and NetworkPolicies

### Sprint 2 — Builds
- [ ] `builds/build.yaml` + Dockerfiles for model-fetch and static-scan
- [ ] Phase 5: build and push all images to Quay
- [ ] Test HF download Job in `model-ingress`

### Sprint 3 — Tekton core
- [ ] Phase 6–7: Tasks + Pipeline (static scan only first)
- [ ] Manual PipelineRun smoke test with tiny HF model (`sshleifer/tiny-gpt2`)
- [ ] Phase 8: Triggers on PVC/object upload

### Sprint 4 — Full evaluation
- [ ] Add dynamic-test, capability-eval, red-team tasks
- [ ] GPU quota for eval tasks
- [ ] Phase 9: Tekton Chains signing

### Sprint 5 — Production
- [ ] Phase 10–11: GitOps + KServe promotion
- [ ] End-to-end: HF download → scan → sign → serve
- [ ] Document rollback / fail-closed behavior

---

## 10. Prerequisites Checklist

Before running `script.sh`:

- [ ] `oc` CLI logged in (`oc whoami`)
- [ ] Cluster admin or sufficient RBAC for operators, SCC, pipelines
- [ ] GPU nodes labeled (see `infra/prereqs/ocp-gpu-setup/README.md`)
- [ ] Quay org + robot account; update `builds/build.yaml` image prefixes
- [ ] Hugging Face token secret for `model-ingress`
- [ ] DNS / routes if exposing upload API (optional phase)
- [ ] Edit hostname in `instances/gateway/gateway.yaml` before overlay 13

---

## 11. Open Questions

| Question | Recommendation |
|----------|----------------|
| ODF vs PVC-only for models? | ODF/NOOBAA for >10GB models |
| Kata in sprint 1? | Defer; use restricted SCC + NetworkPolicy first |
| Separate clusters per zone? | Single cluster for MVP; split later per HLD maturity path |
| Which HF models to test? | Start with `Qwen/Qwen3-0.6B` (see `instances/model-prod/llm-models/qwen-verified.yaml`) |

---

## 12. Related Files

| File | Purpose |
|------|---------|
| [script.sh](./script.sh) | Full deployment runbook (Phases 0–16) |
| [builds/build.yaml](./builds/build.yaml) | Image build definitions |
| [HIGH-LEVEL-DESIGN.md](./HIGH-LEVEL-DESIGN.md) | Architecture reference |
| [infra/prereqs/ocp-gpu-setup/README.md](./infra/prereqs/ocp-gpu-setup/README.md) | GPU node setup |
