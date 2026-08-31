# AI Model Security Platform — Design docs

Zero-trust intake for untrusted LLM weights on **Red Hat OpenShift** and **OpenShift AI**. Artifacts are scanned, scored, and signed in an isolated evaluation zone. Only auto-pass models are registered and served in `model-test`. Promotion to `model-prod` is manual.

The root [README.md](../README.md) is the high-level design (zones, pipeline task and subtask names). Per-subtask **tool tables** (what each scanner does in code) are in [Detailed design](detailed-design.md). This folder is the diagram-first design set for architecture reviews and DemoJam.

## Documents

| Doc | What it covers |
|-----|----------------|
| [Architecture](architecture.md) | Zones, principles, Red Hat product map |
| [Pipeline](pipeline.md) | Tekton DAG, tasks, images, workspaces |
| [Scoring and policy](scoring.md) | `S_total`, hard gates, routing |
| [Zones and network](zones-and-network.md) | Namespaces, NetworkPolicy, SCC, Kata |
| [Storage and registry](storage-and-registry.md) | MinIO buckets, PVC, Model Registry |
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
