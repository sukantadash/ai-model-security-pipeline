# AI Model Security Platform — High-Level Design

**Document:** High-Level Design (HLD)  
**Platform:** OpenShift + Tekton Pipelines  
**Source:** LLM Security Repositories Evaluation  
**Last updated:** August 27, 2026

Design docs and diagrams (architecture, pipeline DAG, scoring, zones, storage, DemoJam) live in **[docs/](docs/)**. Per-subtask **tool tables** (what each scanner does in code) live in **[docs/detailed-design.md](docs/detailed-design.md)**. This README lists task and subtask names only.

---

## 1. Purpose

This document describes the high-level architecture for an AI Model Security Platform deployed on Red Hat OpenShift. The platform validates untrusted Large Language Model (LLM) artifacts through a zero-trust, three-zone pipeline before promoting them to **test** serving. Promotion from `model-test` to `model-prod` is a later manual process.

The design integrates open-source static scanners, dynamic sandbox testing, capability benchmarks, and automated adversarial testing orchestrated by Tekton Pipelines (OpenShift Pipelines), with cryptographic provenance provided by Tekton Chains.

---

## 2. Design Principles

- **Zero trust:** No artifact is trusted until it completes all evaluation tasks and receives a signed attestation.
- **Zone isolation:** Ingress, evaluation, and production workloads run in separate OpenShift projects with strict network boundaries.
- **Fail closed:** Critical scanner findings block promotion; failed artifacts remain in ingress storage.
- **Supply chain integrity:** Tekton Chains generates SLSA Level 2/3 provenance attestations signed with Cosign/Sigstore.
- **GitOps promotion:** Verified models deploy to `model-test` via OpenShift GitOps (Argo CD). `model-prod` is a later manual promotion.

---

## 3. Architecture Overview

Untrusted model artifacts enter the **Ingress Zone**, pass through a four-task Tekton pipeline in the **Evaluation Zone**, and are published as signed artifacts to the **Test Zone**. Promotion to production is manual.

| Zone | OpenShift Namespace | Purpose |
|------|---------------------|---------|
| **Ingress Zone** | `model-ingress` | Untrusted artifact intake and staging |
| **Evaluation Zone** | `model-eval` | Tekton pipeline sandbox for security validation |
| **Sandbox Zone** | `model-sandbox` | Persistent namespace for untrusted eval vLLM (`serve-llm-start`) |
| **Test Zone** | `model-test` | Verified model serving after pipeline pass |
| **Production Zone** | `model-prod` (later) | Manual promotion from test; not deployed by this pipeline |

### 3.1 Architecture Diagram

![Architecture diagram](./docs/diagrams/architecture-overview.svg)

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

### 4.3 Test Zone

Hosts verified models approved for test serving after pipeline pass. Promotion to `model-prod` is a later manual process.

| Component | Repository / Product | Role |
|-----------|---------------------|------|
| Kubeflow Model Registry | `kubeflow/model-registry` | Versioned artifact metadata and RBAC |
| Red Hat Quay | `quay/quay` | Container and model artifact registry |
| Cosign | `sigstore/cosign` | Signature verification at pull time |
| OpenShift GitOps | Argo CD | Declarative deployment to `model-test` |
| KServe + vLLM | `kserve/kserve`, `vllm-project/vllm` | Inference serving |
| KEDA | `kedacore/keda` | GPU and queue-depth autoscaling |
| Observability | Prometheus, Grafana, OpenTelemetry | Operational visibility |

---

## 5. Tekton Pipeline Design

### 5.1 Pipeline Flow

```text
Fetch Artifact → Static Scanning → Dynamic Scan → Capability Eval → Adversarial Test → Score Gate → Sign & Publish
```

| Step | Tekton Task | Description |
|------|-------------|-------------|
| 1 | Fetch and validate artifact | Clone from ingress PVC or object store; verify checksum and file type (Magika) |
| 2 | Sequential security tasks | Four evaluation tasks with `runAfter` dependencies |
| 3 | Score gate | Weighted composite `S_total`; dynamic-scan is a hard gate; routing auto-pass / review / reject |
| 4 | Publish or reject | Auto-pass (`S_total` ≥ 75) and review (55–74): promote to `models-verified` and register. Reject (< 55 or hard-gate): PipelineRun fails, no publish |

### 5.2 Evaluation Tasks

| Task | Purpose | Open-Source Tools | Tekton Pattern |
|------|---------|-------------------|----------------|
| **Static Security Scanning** | Inspect serialization without execution | Magika, ModelAudit, Fickling, ModelScan, ClamAV, Syft, Grype | Parallel Tasks → results aggregation Task |
| **Dynamic Scan** | Load model in isolated VM runtime | Kata, Falco/Tetragon, Kepler, vLLM | Four parallel Tasks + merge Task |
| **Capability Evaluation** | Benchmark quality, performance/cost, stability, and anomaly/bias | HTTP to eval `LLMInferenceService` (lm-eval-harness later) | Four parallel Tasks + merge Task |
| **Adversarial Test** | Adversarial probing and guardrails | HTTP probes (Garak / Promptfoo / LLM Guard later) | Three parallel Tasks + merge Task |

Pipeline runs clone `git-url`, patch `LLMInferenceService.yaml` under `model-sandbox-path`, and apply it in **`model-sandbox`**. Later stages use `model-endpoint`. Isolation probes inspect that serving pod. `serve-llm-stop` deletes the sandbox CR (namespace stays). Auto-pass and review patch `model-test-path` to `s3://models-verified/` and apply in `model-test`.

What each scanner **does in code** (tool name, installed vs fixture, future work) is in **[docs/detailed-design.md](docs/detailed-design.md)**.

#### Fetch artifact

`fetch-artifact` copies weights from MinIO `models-ingress` onto the eval PVC. It is not a scan subtask.

#### Static Security Scanning (Stage 1)

Three Tasks run **in parallel** after `fetch-artifact`, then `static-scan-merge`. Each subtask uploads JSON to `s3://models-eval/<model-id>/<version>/scan-result/`.

| Subtask | Pipeline task | Tekton Task | Scan object |
|---------|---------------|-------------|-------------|
| 1 | `malware` | `static-scan-malware` | `static-malware.json` |
| 2 | `vulnerabilities` | `static-scan-vulnerabilities` | `static-vulnerabilities.json` |
| 3 | `license-compliance` | `static-scan-license-compliance` | `static-license-compliance.json` |
| merge | `static-scan` | `static-scan-merge` | `static-scan.json` |

#### Eval serving (`serve-llm-start` / `serve-llm-stop`)

After `static-scan`, `serve-llm-start` clones `git-url`, patches name + `s3://models-ingress/<model-id>/` in `model-sandbox-path/LLMInferenceService.yaml`, and applies in `model-sandbox`. Stages 2–4 wait until Ready. `serve-llm-stop` deletes the CR only. Auto-pass applies a patched CR in `model-test`.

#### Dynamic Scan (Stage 2)

Four Tasks run **in parallel** after `serve-llm-start`, then `dynamic-scan-merge`. `score-gate` treats `dynamic-scan.json` as a **hard gate** (not part of `S_total`).

| Subtask | Pipeline task | Tekton Task | Scan object |
|---------|---------------|-------------|-------------|
| 1 | `isolated-runtime` | `dynamic-scan-isolated-runtime` | `dynamic-isolated-runtime.json` |
| 2 | `behavior` | `dynamic-scan-behavior` | `dynamic-behavior.json` |
| 3 | `abnormal-resources` | `dynamic-scan-abnormal-resources` | `dynamic-abnormal-resources.json` |
| 4 | `basic-inference` | `dynamic-scan-basic-inference` | `dynamic-basic-inference.json` |
| merge | `dynamic-scan` | `dynamic-scan-merge` | `dynamic-scan.json` |

```text
fetch-artifact ──► malware              ──┐
               ──► vulnerabilities      ──┼──► static-scan-merge ──► serve-llm-start ──► isolated-runtime     ──┐
               ──► license-compliance   ──┘                                 ├──► behavior             ──┤
                                                                            ├──► abnormal-resources   ──┼──► dynamic-scan-merge ──► quality … ──► adversarial … ──► score-gate ──► publish-artifact
                                                                            └──► basic-inference      ──┘
finally: serve-llm-stop, archive-results
```

#### Capability Evaluation (Stage 3)

Four Tasks run **in parallel** after `dynamic-scan`, then `capability-eval-merge`. Pipeline runs pass `model-endpoint` to the eval service.

| Subtask | Pipeline task | Tekton Task | Scan object |
|---------|---------------|-------------|-------------|
| 1 | `quality` | `capability-eval-quality` | `capability-quality.json` |
| 2 | `performance-cost` | `capability-eval-performance-cost` | `capability-performance-cost.json` |
| 3 | `stability-check` | `capability-eval-stability` | `capability-stability.json` |
| 4 | `anomaly-bias-detection` | `capability-eval-anomaly-bias` | `capability-anomaly-bias.json` |
| merge | `capability-eval` | `capability-eval-merge` | `capability.json` |

#### Adversarial Test (Stage 4)

Three Tasks run **in parallel** after `capability-eval`, then `adversarial-test-merge`.

| Subtask | Pipeline task | Tekton Task | Scan object |
|---------|---------------|-------------|-------------|
| 1 | `prompt-injection` | `adversarial-test-prompt-injection` | `adversarial-prompt-injection.json` |
| 2 | `jailbreak-guardrail-bypass` | `adversarial-test-jailbreak-guardrail-bypass` | `adversarial-jailbreak-guardrail-bypass.json` |
| 3 | `harmful-content-bias` | `adversarial-test-harmful-content-bias` | `adversarial-harmful-content-bias.json` |
| merge | `adversarial-test` | `adversarial-test-merge` | `adversarial-test.json` |

#### Score gate

`score-gate` reads the scan prefix and writes `score.json`.

```text
S_total = 0.40 × S_static + 0.35 × S_capability + 0.25 × S_redteam
```

Dynamic-scan is a hard gate and is **not** in the weight.

| `S_total` | Routing | PipelineRun | Publish |
|-----------|---------|-------------|---------|
| ≥ 75 | Auto-pass | Succeeded | `publish-artifact` runs |
| 55–74 | Manual review | Succeeded | `publish-artifact` runs |
| < 55, missing JSON, or dynamic hard-gate | Reject | Failed | skipped |

Finding schema, penalty tables, and `policy.json` behavior: [docs/detailed-design.md](docs/detailed-design.md#5-score-gate).

#### Publish artifact

Runs when score-gate routing is `auto-pass` or `review`. Promotes weights to `models-verified` and registers the model. Reject does not publish.

#### Archive results

Pipeline `finally` Task. Always runs. Writes `manifest.json` in the scan-result prefix.

---

## 6. OpenShift Platform Mapping

| Layer | Component | Role |
|-------|-----------|------|
| Orchestration | OpenShift Pipelines (Tekton) | Pipeline, Task, PipelineRun CRDs |
| Supply chain | Tekton Chains + Cosign | Digest, sign, store attestations |
| Isolation | NetworkPolicy + SCC | Zone egress deny, restricted pods |
| Sandbox runtime | Sandboxed Containers (Kata) | VM-level workload isolation |
| Secrets | Vault / OCP Secrets | KMS keys for Chains signing |
| GitOps | OpenShift GitOps (Argo CD) | Promote verified models to `model-test` |
| Serving | KServe + KEDA | Inference + GPU autoscaling |

---

## 7. Cross-Cutting Concerns

### 7.1 Network Isolation

- Separate OpenShift projects per zone (`model-ingress`, `model-eval`, `model-test`)
- NetworkPolicies deny east-west traffic except approved artifact transfer paths
- Evaluation namespace has no default egress to public internet
- Stage 2 `dynamic-scan` pods use a tighter NetworkPolicy (DNS only); they must not reach internal APIs or the public internet during the probe

### 7.2 Supply Chain Security (SLSA)

- Tekton Chains watches completed PipelineRuns
- Computes artifact digests and generates signed provenance attestations using x509 or KMS keys
- Stores attestations in Sigstore/Cosign backends for SLSA Level 2/3 compliance
- Promotion to the test zone requires valid attestation

### 7.3 Test Zone Promotion

- Cosign verifies signatures at registry pull time
- Argo CD syncs KServe InferenceServices to the `model-test` namespace
- Promotion from `model-test` to `model-prod` is a later manual process
- KEDA scales vLLM pods based on request queue depth and GPU concurrency

---

## 8. Implementation Starting Point

Begin with a **single OpenShift cluster** and three namespaces:

```text
model-ingress  →  model-eval  →  model-test
# later, manual: model-test → model-prod
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
| 1.2 | 2026-08-27 | — | Move tool tables to [docs/detailed-design.md](docs/detailed-design.md); README keeps task/subtask names |
| 1.1 | 2026-08-27 | — | Document every pipeline Task/subtask with tool tables; move shared finding schema to score-gate |
| 1.0 | 2026-08-20 | — | Initial high-level design based on LLM Security Repositories Evaluation |
