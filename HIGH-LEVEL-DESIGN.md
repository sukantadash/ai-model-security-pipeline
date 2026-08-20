# AI Model Security Platform — High-Level Design

**Document:** High-Level Design (HLD)  
**Platform:** OpenShift + Tekton Pipelines  
**Source:** LLM Security Repositories Evaluation  
**Last updated:** August 20, 2026

---

## 1. Purpose

This document describes the high-level architecture for an AI Model Security Platform deployed on Red Hat OpenShift. The platform validates untrusted Large Language Model (LLM) artifacts through a zero-trust, three-zone pipeline before promoting them to production inference environments.

The design integrates open-source static scanners, dynamic sandbox testing, capability benchmarks, and automated red teaming orchestrated by Tekton Pipelines (OpenShift Pipelines), with cryptographic provenance provided by Tekton Chains.

---

## 2. Design Principles

- **Zero trust:** No artifact is trusted until it completes all evaluation tasks and receives a signed attestation.
- **Zone isolation:** Ingress, evaluation, and production workloads run in separate OpenShift projects with strict network boundaries.
- **Fail closed:** Critical scanner findings block promotion; failed artifacts remain in ingress storage.
- **Supply chain integrity:** Tekton Chains generates SLSA Level 2/3 provenance attestations signed with Cosign/Sigstore.
- **GitOps promotion:** Verified models deploy to production via OpenShift GitOps (Argo CD).

---

## 3. Architecture Overview

Untrusted model artifacts enter the **Ingress Zone**, pass through a four-task Tekton pipeline in the **Evaluation Zone**, and are published as signed artifacts to the **Production Zone**.

| Zone | OpenShift Namespace | Purpose |
|------|---------------------|---------|
| **Ingress Zone** | `model-ingress` | Untrusted artifact intake and staging |
| **Evaluation Zone** | `model-eval` | Tekton pipeline sandbox for security validation |
| **Production Zone** | `model-prod` | Verified model registry, serving, and observability |

### 3.1 Architecture Diagram

![Architecture diagram](./architecture-diagram.svg)

*Figure: Ingress, Evaluation, and Production zones with Tekton pipeline tasks, score gate, and signed artifact promotion.*

---

## 4. Zone Descriptions

### 4.1 Ingress Zone

Single entry point for untrusted model weights from public model hubs or third-party vendors.

| Component | Repository / Product | Role |
|-----------|---------------------|------|
| Envoy Proxy | `envoyproxy/envoy` | Ingress gateway with rate limiting and egress blockade |
| Ingress Storage | PVC / object store | Staging area for multi-GB artifacts (GGUF, Safetensors, PyTorch) |

**Controls:**
- Strict network isolation at the perimeter
- Chunked upload handling for large binary artifacts
- No outbound connections from untrusted storage

### 4.2 Evaluation Zone

Workflow orchestration managed by OpenShift Pipelines (Tekton). Tasks run in an isolated namespace with no default egress to the public internet.

| Component | Repository / Product | Role |
|-----------|---------------------|------|
| Tekton Triggers | `tektoncd/triggers` | EventListener fires PipelineRun on artifact upload |
| OpenShift Pipelines | `tektoncd/pipeline` | Orchestrates security tasks and score aggregation |
| Tekton Chains | `tektoncd/chains` | Hashes artifacts, signs provenance, stores attestations |
| Sandboxed Containers | Kata Containers | VM-level isolation for dynamic runtime testing |

**Controls:**
- NetworkPolicies deny east-west traffic except approved artifact transfer paths
- Security Context Constraints (SCC) enforce restricted pod profiles
- Tekton Tasks run with no outbound egress except approved endpoints

### 4.3 Production Zone

Hosts verified models approved for development and production deployment.

| Component | Repository / Product | Role |
|-----------|---------------------|------|
| Kubeflow Model Registry | `kubeflow/model-registry` | Versioned artifact metadata and RBAC |
| Red Hat Quay | `quay/quay` | Container and model artifact registry |
| Cosign | `sigstore/cosign` | Signature verification at pull time |
| OpenShift GitOps | Argo CD | Declarative deployment to model-dev / model-prod |
| KServe + vLLM | `kserve/kserve`, `vllm-project/vllm` | Inference serving |
| KEDA | `kedacore/keda` | GPU and queue-depth autoscaling |
| Observability | Prometheus, Grafana, OpenTelemetry | Operational visibility |

---

## 5. Tekton Pipeline Design

### 5.1 Pipeline Flow

```text
Fetch Artifact → Static Scanning → Dynamic Testing → Capability Eval → Red Teaming → Score Gate → Sign & Publish
```

| Step | Tekton Task | Description |
|------|-------------|-------------|
| 1 | Fetch and validate artifact | Clone from ingress PVC or object store; verify checksum and file type (Magika) |
| 2 | Sequential security tasks | Four evaluation tasks with `runAfter` dependencies |
| 3 | Aggregate security score | Custom Task merges scanner JSON into pass/fail gate; fail fast on critical findings |
| 4 | Publish or reject | On pass: push to Quay/Kubeflow registry and sign with Tekton Chains; on fail: alert and retain in ingress storage |

### 5.2 Evaluation Tasks

| Task | Purpose | Open-Source Tools | Tekton Pattern |
|------|---------|-------------------|----------------|
| **Static Security Scanning** | Inspect serialization without execution | Magika, ModelAudit, Fickling, ModelScan, ClamAV, Syft/Clair | Parallel Tasks → results aggregation Task |
| **Dynamic Runtime Testing** | Load model in isolated VM runtime | Kata Containers, Falco/Tetragon, Kepler, vLLM probe | RuntimeClass Task + sidecar monitoring |
| **Capability Evaluation** | Benchmark quality and safety baselines | InstructLab, lm-eval-harness, DeepEval, TruLens | Benchmark TaskRun with GPU quota |
| **Adversarial Red Teaming** | Adversarial probing and guardrails | Garak, PyRIT, Promptfoo, LLM Guard | Conditional Task on prior pass score |

#### Static Security Scanning

Processes model artifacts on disk without executing underlying model code. Inspects serialization headers, byte sequences, opcodes, and embedded dependencies.

Supported formats: PyTorch (`.pt`, `.bin`), Pickle (`.pkl`), GGUF, Safetensors, Keras, TensorFlow SavedModel, TFLite, Joblib, NumPy.

#### Dynamic Runtime Testing

Loads model weights into memory within Kata Container VMs. Monitors system calls, network egress, resource utilization, and operational stability via Falco/Tetragon rules.

Requires OpenShift RuntimeClass configured for VFIO GPU passthrough when GPU validation is needed.

#### Capability Evaluation

Assesses baseline quality, logic, and safety benchmarks (MMLU, GSM8K, HumanEval) and detects output distribution anomalies.

#### Adversarial Red Teaming

Subjects the model to automated adversarial attacks: prompt injections, jailbreaks, system prompt leaks, and harmful content generation.

---

## 6. OpenShift Platform Mapping

| Layer | Component | Role |
|-------|-----------|------|
| Orchestration | OpenShift Pipelines (Tekton) | Pipeline, Task, PipelineRun CRDs |
| Supply chain | Tekton Chains + Cosign | Digest, sign, store attestations |
| Isolation | NetworkPolicy + SCC | Zone egress deny, restricted pods |
| Sandbox runtime | Sandboxed Containers (Kata) | VM-level workload isolation |
| Secrets | Vault / OCP Secrets | KMS keys for Chains signing |
| GitOps | OpenShift GitOps (Argo CD) | Promote verified models to production |
| Serving | KServe + KEDA | Inference + GPU autoscaling |

---

## 7. Cross-Cutting Concerns

### 7.1 Network Isolation

- Separate OpenShift projects per zone (`model-ingress`, `model-eval`, `model-prod`)
- NetworkPolicies deny east-west traffic except approved artifact transfer paths
- Evaluation namespace has no default egress to public internet

### 7.2 Supply Chain Security (SLSA)

- Tekton Chains watches completed PipelineRuns
- Computes artifact digests and generates signed provenance attestations using x509 or KMS keys
- Stores attestations in Sigstore/Cosign backends for SLSA Level 2/3 compliance
- Promotion to the production zone requires valid attestation

### 7.3 Production Zone Promotion

- Cosign verifies signatures at registry pull time
- Argo CD syncs KServe InferenceServices to `model-dev` and `model-prod` namespaces
- KEDA scales vLLM pods based on request queue depth and GPU concurrency

---

## 8. Implementation Starting Point

Begin with a **single OpenShift cluster** and three namespaces:

```text
model-ingress  →  model-eval  →  model-prod
```

1. Deploy OpenShift Pipelines and Tekton Chains in `model-eval`.
2. Configure Tekton Triggers (EventListener) to fire a PipelineRun when an artifact lands in ingress storage.
3. Implement the four evaluation tasks as Tekton Tasks with a score-aggregation gate Task.
4. Enable Tekton Chains signing before any artifact reaches the production registry.
5. Wire OpenShift GitOps to promote verified models to KServe InferenceServices.

**Maturity path:** Add physical cluster separation per zone and Kata GPU passthrough as the pipeline matures.

---

## 9. References

| Reference | Description |
|-----------|-------------|
| LLM Security Repositories Evaluation.pdf | Source evaluation of open-source scanning tools and architecture model |
| `tektoncd/pipeline` | Tekton Pipelines |
| `tektoncd/chains` | Tekton Chains supply chain attestation |
| `promptfoo/modelaudit` | Primary static inspection engine |
| `trailofbits/fickling` | Pickle bytecode decompiler and allowlist hooks |
| `kata-containers/kata-containers` | VM-level sandbox isolation |
| `sigstore/cosign` | Container and artifact signing |

---

## 10. Document History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2026-08-20 | — | Initial high-level design based on LLM Security Repositories Evaluation |
