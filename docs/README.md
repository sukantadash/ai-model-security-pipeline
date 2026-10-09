# AI Model Security Platform — Design docs

Zero-trust intake for untrusted LLM weights on **Red Hat OpenShift** and **OpenShift AI**. Artifacts are scanned, scored, and signed in an isolated evaluation zone, attacked with and without NeMo Guardrails, and every run is tracked in MLflow. Models that pass or need review are registered and served in `model-test`. Promotion to `model-prod` is manual. The same pipeline compares models (Qwen3, Granite 4.1, Llama 3.1).

The root [README.md](../README.md) is the high-level design (zones, pipeline task and subtask names). Per-subtask **tool tables** (what each scanner does in code) are in [Detailed design](detailed-design.md). This folder is the diagram-first design set for architecture reviews and DemoJam.

## Documents

| Doc | What it covers |
|-----|----------------|
| [Architecture](architecture.md) | Zones, principles, Red Hat product map |
| [Pipeline](pipeline.md) | Tekton DAG, tasks, images, workspaces |
| [Scoring and policy](scoring.md) | `S_total`, hard gates, routing |
| [Zones and network](zones-and-network.md) | Namespaces, NetworkPolicy, SCC, Kata |
| [Storage and registry](storage-and-registry.md) | Quay ModelCar tags, MinIO buckets, PVC, Model Registry, MLflow |
| [NeMo Guardrails](nemo-guardrails.md) | TrustyAI `NemoGuardrails` in sandbox + test, rails, adversarial subtask |
| [Deployment steps](../Deployment_Steps.md) | Install, test, compare models (5.6), MLflow tracking (5.7), troubleshooting |
| [Detailed design](detailed-design.md) | Tool tables, per-subtask activities, and further improvements (fetch through archive) |
| [DemoJam](demojam.md) | Proposal copy, demo outline, upload asset |

## Diagrams

SVG in [`diagrams/`](diagrams/).

| Diagram | File |
|---------|------|
| Three-zone overview | [architecture-overview.svg](diagrams/architecture-overview.svg) |
| Tekton pipeline DAG | [pipeline-dag.svg](diagrams/pipeline-dag.svg) |
| Zone network / egress | [zones-network.svg](diagrams/zones-network.svg) |
| Storage and scan-result flow | [storage-flow.svg](diagrams/storage-flow.svg) |
| Score gate and routing | [score-gate.svg](diagrams/score-gate.svg) |
| GitOps promotion | [gitops-promotion.svg](diagrams/gitops-promotion.svg) |
| DemoJam slide | [demojam-architecture.svg](diagrams/demojam-architecture.svg) |

Regenerate SVG with [`diagrams/generate.py`](diagrams/generate.py).

## Source of truth in the repo

| Topic | Path |
|-------|------|
| Pipeline graph | `instances/tekton-pipeline/pipeline.yaml` |
| Score policy | `builds/score-gate/policy.json` |
| License policy | `builds/static-scan/policy.json` |
| Zone NetworkPolicies | `instances/model-ingress/`, `model-eval/`, `model-sandbox/`, `model-test/` |
| Overlays | `overlays/00-gpu-operators` … `17-gitops` |
| Scanner images | `builds/` |
| NeMo Guardrails rails | `instances/nemo-guardrails/config/` |
| Models (per-model serving YAML) | `instances/model-sandbox/LLMInferenceService*.yaml`, `instances/model-test/*-verified.yaml`, `deploy.sh` (`use_model`) |
| MLflow server / logging | `instances/mlflow/`, `builds/publish/scripts/log_mlflow.py` |
| Model comparison report | `tools/compare_models.py` |
