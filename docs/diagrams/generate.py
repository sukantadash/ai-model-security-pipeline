#!/usr/bin/env python3
"""Generate docs/diagrams/*.svg (ASCII labels only; XML-safe).

Run from repo root:
  python3 docs/diagrams/generate.py
"""
from __future__ import annotations

from pathlib import Path
from xml.sax.saxutils import escape

OUT = Path(__file__).resolve().parent

BG = "#F8F8F8"
WHITE = "#FFFFFF"
INK = "#151515"
MUTED = "#6A6E73"
RED = "#C9190B"
BLUE = "#0066CC"
GREEN = "#3E8635"
GOLD = "#F0AB00"
STROKE = "#D2D2D2"
FILL_RED = "#FFF5F5"
FILL_BLUE = "#E7F1FA"
FILL_GREEN = "#E9F7E6"
FILL_GOLD = "#FFF4D4"
FILL_GRAY = "#F5F5F5"
FONT = "system-ui, -apple-system, Segoe UI, sans-serif"


def T(x, y, s, size=12, fill=INK, weight="400", anchor="start", family=FONT):
    return (
        f'<text x="{x}" y="{y}" fill="{fill}" font-size="{size}" '
        f'font-weight="{weight}" text-anchor="{anchor}" font-family="{family}">{escape(s)}</text>'
    )


def R(x, y, w, h, fill=WHITE, stroke=STROKE, sw=1, rx=6):
    return (
        f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" '
        f'fill="{fill}" stroke="{stroke}" stroke-width="{sw}"/>'
    )


def Rdash(x, y, w, h, fill=WHITE, stroke=RED, sw=2, rx=10):
    return (
        f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" '
        f'fill="{fill}" stroke="{stroke}" stroke-width="{sw}" stroke-dasharray="7 5"/>'
    )


def line(x1, y1, x2, y2, stroke=STROKE, sw=1.5):
    return f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{stroke}" stroke-width="{sw}"/>'


def arrow_def(uid="arr"):
    return (
        f'<defs><marker id="{uid}" markerWidth="8" markerHeight="8" refX="6" refY="3" orient="auto">'
        f'<path d="M0,0 L6,3 L0,6" fill="#6A6E73"/></marker></defs>'
    )


def al(x1, y1, x2, y2, stroke="#6A6E73", sw=1.5, mid="arr"):
    return (
        f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{stroke}" '
        f'stroke-width="{sw}" marker-end="url(#{mid})"/>'
    )


def wrap(w, h, body, label):
    return (
        f'<?xml version="1.0" encoding="UTF-8"?>\n'
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" '
        f'role="img" aria-label="{escape(label)}">\n'
        f'{R(0, 0, w, h, BG, BG, 0, 0)}\n'
        f"{body}\n</svg>\n"
    )


def box(x, y, w, h, title, sub="", fill=FILL_GRAY, stroke=STROKE, title_size=12):
    parts = [R(x, y, w, h, fill, stroke, 1, 6)]
    parts.append(T(x + 12, y + 22, title, title_size, INK, "600"))
    if sub:
        parts.append(T(x + 12, y + 40, sub, 11, MUTED))
    return "\n".join(parts)


def write(name: str, svg: str) -> None:
    path = OUT / name
    path.write_text(svg, encoding="utf-8")
    print("wrote", path.name, path.stat().st_size)


def architecture_overview() -> str:
    parts = [arrow_def()]
    parts.append(T(40, 40, "AI Model Security Platform", 20, INK, "700"))
    parts.append(T(40, 62, "Zero-trust LLM intake on OpenShift + OpenShift AI. Fail closed.", 13, MUTED))
    parts += [
        T(980, 36, "OpenShift", 11, "#fff", "600", "middle"),
        R(930, 20, 100, 24, RED, RED, 0, 4),
        T(980, 36, "OpenShift", 11, "#fff", "600", "middle"),
        R(1040, 20, 118, 24, BLUE, BLUE, 0, 4),
        T(1099, 36, "OpenShift AI", 11, "#fff", "600", "middle"),
        R(1168, 20, 64, 24, INK, INK, 0, 4),
        T(1200, 36, "RHEL", 11, "#fff", "600", "middle"),
        R(1242, 20, 118, 24, "#3D2C29", "#3D2C29", 0, 4),
        T(1301, 36, "GitOps / Quay", 11, "#fff", "600", "middle"),
    ]
    # redraw chips properly (first T was before rect)
    parts = [arrow_def()]
    parts.append(T(40, 40, "AI Model Security Platform", 20, INK, "700"))
    parts.append(T(40, 62, "Zero-trust LLM intake on OpenShift + OpenShift AI. Fail closed.", 13, MUTED))
    chips = [
        (930, RED, 100, "OpenShift"),
        (1040, BLUE, 118, "OpenShift AI"),
        (1168, INK, 64, "RHEL"),
        (1242, "#3D2C29", 118, "GitOps / Quay"),
    ]
    for x, color, w, label in chips:
        parts.append(R(x, 20, w, 24, color, color, 0, 4))
        parts.append(T(x + w / 2, 37, label, 11, "#fff", "600", "middle"))

    # zones
    parts.append(Rdash(24, 88, 280, 680, WHITE, RED, 2, 10))
    parts.append(T(44, 116, "1. Ingress", 16, RED, "700"))
    parts.append(T(44, 136, "model-ingress", 12, MUTED))
    parts.append(T(44, 154, "Untrusted. No trust assumed.", 11, MUTED))
    parts.append(box(44, 176, 240, 70, "Model hubs / vendors", "Hugging Face, GGUF, Safetensors, PyTorch"))
    parts.append(box(44, 258, 240, 70, "Envoy + NetworkPolicy", "Rate limit, egress blockade", FILL_RED, RED))
    parts.append(box(44, 340, 240, 70, "MinIO models-ingress", "s3://models-ingress/<model-id>/"))
    parts.append(box(44, 422, 240, 70, "Tekton Trigger", "EventListener fires PipelineRun", FILL_RED, RED))
    parts.append(T(164, 530, "artifact event ->", 12, RED, "600", "middle"))

    parts.append(R(328, 88, 720, 680, WHITE, BLUE, 2, 10))
    parts.append(T(348, 116, "2. Evaluation  |  OpenShift Pipelines", 16, BLUE, "700"))
    parts.append(T(348, 136, "model-eval  |  no public HF  |  restricted SCC  |  Kata target", 12, MUTED))

    stages = [
        (348, 160, 160, "Static scan", "Malware, CVE, license", "40% of S_total", FILL_BLUE, BLUE),
        (524, 160, 160, "Dynamic scan", "Kata, Falco, Kepler, vLLM", "Hard gate", FILL_RED, RED),
        (700, 160, 160, "Capability", "Quality, cost, stability, bias", "35% of S_total", FILL_BLUE, BLUE),
        (876, 160, 148, "Adversarial", "Injection, jailbreak, harm", "25% of S_total", FILL_BLUE, BLUE),
    ]
    for x, y, w, t, s, f, fill, st in stages:
        parts.append(R(x, y, w, 92, fill, st, 1, 6))
        parts.append(T(x + 10, y + 22, t, 13, INK, "700"))
        parts.append(T(x + 10, y + 42, s, 10, MUTED))
        parts.append(T(x + 10, y + 72, f, 11, st, "600"))

    parts.append(R(348, 268, 676, 168, FILL_GRAY, STROKE, 1, 8))
    parts.append(T(368, 296, "DAG: fetch -> static(3) -> dynamic(4) -> capability(4) -> adversarial(3) -> gate", 12, INK, "600"))
    parts.append(T(368, 318, "S_total = 0.40*S_static + 0.35*S_capability + 0.25*S_redteam", 12, MUTED))
    parts.append(R(368, 338, 200, 76, GREEN, GREEN, 0, 6))
    parts.append(T(468, 368, ">= 75  Auto-pass", 14, "#fff", "700", "middle"))
    parts.append(T(468, 388, "Sign, promote, serve", 11, "#fff", "400", "middle"))
    parts.append(R(584, 338, 200, 76, GOLD, GOLD, 0, 6))
    parts.append(T(684, 368, "55-74  Review", 14, INK, "700", "middle"))
    parts.append(T(684, 388, "Succeeds, publish", 11, INK, "400", "middle"))
    parts.append(R(800, 338, 200, 76, RED, RED, 0, 6))
    parts.append(T(900, 368, "< 55 / hard gate", 14, "#fff", "700", "middle"))
    parts.append(T(900, 388, "Reject, stay quarantined", 11, "#fff", "400", "middle"))

    parts.append(box(348, 452, 328, 100, "Score gate + Tekton Chains", "Policy-as-code. SLSA provenance. Cosign on PipelineRun.", FILL_BLUE, BLUE))
    parts.append(box(696, 452, 328, 100, "Scanner images on RHEL UBI 9", "BuildConfig in build-image -> Quay / internal registry.", FILL_GRAY, STROKE))
    parts.append(T(688, 590, "signed, scored artifact ->", 12, BLUE, "600", "middle"))
    parts.append(T(688, 720, "Tasks isolated. Dynamic probes DNS-only. Scan JSON in MinIO, not the eval PVC.", 11, MUTED, "400", "middle"))

    parts.append(Rdash(1072, 88, 344, 680, WHITE, GREEN, 2, 10))
    parts.append(T(1092, 116, "3. Test", 16, GREEN, "700"))
    parts.append(T(1092, 136, "OpenShift AI  |  model-test", 12, MUTED))
    parts.append(T(1092, 154, "Only auto-pass models arrive.", 11, MUTED))
    parts.append(box(1092, 176, 304, 70, "RHOAI Model Registry", "version, storage_uri, scan_uri", FILL_GREEN, GREEN))
    parts.append(box(1092, 258, 304, 70, "Quay + Cosign", "Scanner images; verify at pull"))
    parts.append(box(1092, 340, 304, 70, "OpenShift GitOps", "Argo CD syncs LLMInferenceService", FILL_GREEN, GREEN))
    parts.append(box(1092, 422, 304, 70, "KServe + vLLM", "Live chat only after the gate", FILL_GREEN, GREEN))
    parts.append(box(1092, 504, 304, 70, "KEDA + observability", "GPU / queue scale; Prometheus"))
    parts.append(box(1092, 586, 304, 88, "model-prod (later, manual)", "Demo stops at signed test serving."))
    return wrap(1440, 810, "\n".join(parts), "Three-zone AI model security architecture")


def pipeline_dag() -> str:
    parts = [arrow_def()]
    parts.append(T(40, 36, "model-security-pipeline  |  OpenShift Pipelines DAG", 18, INK, "700"))
    parts.append(T(40, 58, "Parallel subtasks merge before the next stage. publish is conditional. archive-results is finally.", 12, MUTED))

    cols = [
        (28, "Fetch", BLUE),
        (200, "Static", BLUE),
        (430, "Dynamic (hard gate)", RED),
        (700, "Capability (GPU)", BLUE),
        (990, "Adversarial (GPU)", BLUE),
        (1280, "Gate", GREEN),
    ]
    for x, title, c in cols:
        parts.append(T(x, 88, title, 13, c, "700"))

    def node(x, y, w, h, title, sub="", fill=FILL_GRAY, stroke=STROKE):
        parts.append(R(x, y, w, h, fill, stroke, 1, 6))
        parts.append(T(x + 8, y + 20, title, 11, INK, "600"))
        if sub:
            parts.append(T(x + 8, y + 38, sub, 10, MUTED))

    node(28, 280, 150, 56, "fetch-artifact", "MinIO -> eval PVC", FILL_BLUE, BLUE)

    static = [
        (200, 120, "malware", "Magika, ModelAudit, ClamAV"),
        (200, 200, "vulnerabilities", "Syft + Grype"),
        (200, 280, "license-compliance", "SPDX + policy.json"),
    ]
    for x, y, t, s in static:
        node(x, y, 200, 64, t, s)
    node(200, 400, 200, 56, "static-scan", "merge -> static-scan.json", FILL_BLUE, BLUE)

    dyn = [
        (430, 108, "isolated-runtime", "Kata DMI + NP probe"),
        (430, 180, "behavior", "Falco fixture"),
        (430, 252, "abnormal-resources", "Kepler fixture"),
        (430, 324, "basic-inference", "vLLM / weight walk"),
    ]
    for x, y, t, s in dyn:
        node(x, y, 240, 62, t, s, FILL_RED, RED)
    node(430, 410, 240, 56, "dynamic-scan", "merge; hard gate", FILL_RED, RED)

    cap = [
        (700, 108, "quality", "MMLU / GSM8K / HumanEval"),
        (700, 180, "performance-cost", "p99, tok/s, USD"),
        (700, 252, "stability-check", "p99/p50, jitter"),
        (700, 324, "anomaly-bias-detection", "regression / bias"),
    ]
    for x, y, t, s in cap:
        node(x, y, 260, 62, t, s, FILL_BLUE, BLUE)
    node(700, 410, 260, 56, "capability-eval", "merge -> capability.json", FILL_BLUE, BLUE)

    adv = [
        (990, 140, "prompt-injection", "ASR threshold"),
        (990, 220, "jailbreak-guardrail-bypass", "bypass rate"),
        (990, 300, "harmful-content-bias", "harm / bias / illegal"),
    ]
    for x, y, t, s in adv:
        node(x, y, 260, 64, t, s, FILL_BLUE, BLUE)
    node(990, 400, 260, 56, "adversarial-test", "merge -> adversarial-test.json", FILL_BLUE, BLUE)

    node(1280, 200, 200, 64, "score-gate", "score.json + routing", FILL_BLUE, BLUE)
    node(1280, 300, 200, 64, "publish-artifact", "when passed=true", FILL_GREEN, GREEN)
    node(1280, 400, 200, 64, "archive-results", "finally: always", FILL_GOLD, GOLD)

    # arrows fetch -> static column
    parts.append(al(178, 308, 200, 152))
    parts.append(al(178, 308, 200, 232))
    parts.append(al(178, 308, 200, 312))
    parts.append(al(300, 400, 300, 400))  # noop-ish
    for y in (152, 232, 312):
        parts.append(al(400, y, 430, 438) if False else "")
    parts = [p for p in parts if p]

    # merge arrows static
    for y in (152, 232, 312):
        parts.append(al(400, y + 10, 300, 400))
    parts.append(al(400, 428, 430, 438))

    # actually those merge arrows are messy. Draw simple stage arrows at the bottom.
    # Remove the last merge attempts by not using them - draw horizontal stage flow instead.

    # Rebuild arrows more cleanly: right edge of merge boxes to next column merge
    # I'll simplify: only draw stage-level arrows between merge boxes + fetch to first column.

    # Drop the messy ones - regenerate arrow section from scratch at the end.
    return _pipeline_dag_v2()


def _pipeline_dag_v2() -> str:
    parts = [arrow_def("arr")]
    parts.append(T(32, 36, "model-security-pipeline  |  OpenShift Pipelines DAG", 18, INK, "700"))
    parts.append(T(32, 58, "Source: instances/tekton-pipeline/pipeline.yaml. Merges always succeed. publish is when passed=true.", 12, MUTED))

    # swimlane background
    lanes = [
        (20, FILL_BLUE, "Fetch"),
        (190, FILL_GRAY, "Stage 1  Static"),
        (430, FILL_RED, "Stage 2  Dynamic  (hard gate)"),
        (720, FILL_BLUE, "Stage 3  Capability  (GPU)"),
        (1020, FILL_BLUE, "Stage 4  Adversarial  (GPU)"),
        (1320, FILL_GREEN, "Gate / publish"),
    ]
    # just titles
    titles = [
        (40, "Fetch", BLUE),
        (210, "1. Static", BLUE),
        (450, "2. Dynamic (hard gate)", RED),
        (740, "3. Capability (GPU)", BLUE),
        (1040, "4. Adversarial (GPU)", BLUE),
        (1340, "Gate", GREEN),
    ]
    for x, title, c in titles:
        parts.append(T(x, 86, title, 13, c, "700"))

    def node(x, y, w, h, title, sub="", fill=FILL_GRAY, stroke=STROKE):
        parts.append(R(x, y, w, h, fill, stroke, 1, 6))
        parts.append(T(x + 10, y + 22, title, 12, INK, "600"))
        if sub:
            parts.append(T(x + 10, y + 40, sub, 10, MUTED))

    # fetch
    node(32, 300, 150, 64, "fetch-artifact", "PVC /models", FILL_BLUE, BLUE)

    # static stack
    node(200, 120, 210, 58, "malware", "ModelAudit, Fickling, ClamAV")
    node(200, 190, 210, 58, "vulnerabilities", "Syft + Grype")
    node(200, 260, 210, 58, "license-compliance", "allow / copyleft / deny")
    node(200, 400, 210, 58, "static-scan", "static-scan.json", FILL_BLUE, BLUE)

    # dynamic
    node(440, 110, 250, 56, "isolated-runtime", "Kata DMI + NetworkPolicy")
    node(440, 176, 250, 56, "behavior", "Falco alerts JSON")
    node(440, 242, 250, 56, "abnormal-resources", "Kepler samples JSON")
    node(440, 308, 250, 56, "basic-inference", "weights / vLLM ping")
    node(440, 400, 250, 58, "dynamic-scan", "dynamic-scan.json", FILL_RED, RED)

    # capability
    node(730, 110, 260, 56, "quality", "MMLU / GSM8K / HumanEval")
    node(730, 176, 260, 56, "performance-cost", "p99, tokens/sec, USD")
    node(730, 242, 260, 56, "stability-check", "p99/p50, jitter, timeouts")
    node(730, 308, 260, 56, "anomaly-bias-detection", "regression / bias / anomaly")
    node(730, 400, 260, 58, "capability-eval", "capability.json", FILL_BLUE, BLUE)

    # adversarial
    node(1030, 140, 270, 58, "prompt-injection", "attack success rate")
    node(1030, 214, 270, 58, "jailbreak-guardrail-bypass", "bypass rate")
    node(1030, 288, 270, 58, "harmful-content-bias", "harmful rate / illegal")
    node(1030, 400, 270, 58, "adversarial-test", "adversarial-test.json", FILL_BLUE, BLUE)

    # gate
    node(1340, 180, 220, 64, "score-gate", "S_total + routing", FILL_BLUE, BLUE)
    node(1340, 270, 220, 64, "publish-artifact", "when passed=true", FILL_GREEN, GREEN)
    node(1340, 400, 220, 64, "archive-results", "finally (always)", FILL_GOLD, GOLD)

    # arrows: fetch to each static
    for y in (149, 219, 289):
        parts.append(al(182, 332, 200, y))
    for y in (149, 219, 289):
        parts.append(al(410, y, 305, 400))
    parts.append(al(410, 429, 440, 429))

    for y in (138, 204, 270, 336):
        parts.append(al(690, y, 565, 429) if False else al(690, 429, 730, 429))
    # dynamic children to merge
    for y in (138, 204, 270, 336):
        parts.append(al(690, y, 565, 429))
    # wait that's leftward. From right of child to merge top.
    # child right x=690, merge is at y=400. Draw down to merge.
    # Actually children are ABOVE merge in same column. Vertical ticks:
    # skip individual child->merge (implied by column) and only draw merge->next merge.

    # Cleaner: remove the bad leftward arrows. I'll filter after by not adding them.

    # Re-do: only horizontal between merge boxes + fetch to static + score flow
    # Too late - I already added leftward. Let me not use this function's first arrows.

    return _pipeline_clean()


def _pipeline_clean() -> str:
    """Column DAG with vertical implied parallelism; arrows only between stage merges."""
    parts = [arrow_def("arr")]
    parts.append(T(32, 38, "model-security-pipeline  |  OpenShift Pipelines DAG", 18, INK, "700"))
    parts.append(T(32, 60, "instances/tekton-pipeline/pipeline.yaml   |   parallel subtasks, then merge   |   publish when passed=true", 12, MUTED))

    def hdr(x, s, c):
        parts.append(T(x, 88, s, 13, c, "700"))

    hdr(40, "Fetch", BLUE)
    hdr(210, "1. Static", BLUE)
    hdr(450, "2. Dynamic (hard gate)", RED)
    hdr(740, "3. Capability (GPU)", BLUE)
    hdr(1040, "4. Adversarial (GPU)", BLUE)
    hdr(1340, "Gate", GREEN)

    def node(x, y, w, h, title, sub="", fill=FILL_GRAY, stroke=STROKE):
        parts.append(R(x, y, w, h, fill, stroke, 1, 6))
        parts.append(T(x + 10, y + 22, title, 12, INK, "600"))
        if sub:
            parts.append(T(x + 10, y + 40, sub, 10, MUTED))

    node(32, 250, 156, 64, "fetch-artifact", "MinIO -> PVC", FILL_BLUE, BLUE)

    node(208, 120, 210, 58, "malware", "ModelAudit, Fickling, ClamAV")
    node(208, 190, 210, 58, "vulnerabilities", "Syft + Grype")
    node(208, 260, 210, 58, "license-compliance", "allow / copyleft / deny")
    node(208, 430, 210, 58, "static-scan", "static-scan.json", FILL_BLUE, BLUE)

    node(448, 110, 250, 56, "isolated-runtime", "Kata DMI + NetworkPolicy")
    node(448, 176, 250, 56, "behavior", "Falco alerts JSON")
    node(448, 242, 250, 56, "abnormal-resources", "Kepler samples JSON")
    node(448, 308, 250, 56, "basic-inference", "weights / vLLM ping")
    node(448, 430, 250, 58, "dynamic-scan", "dynamic-scan.json", FILL_RED, RED)

    node(738, 110, 260, 56, "quality", "MMLU / GSM8K / HumanEval")
    node(738, 176, 260, 56, "performance-cost", "p99, tokens/sec, USD")
    node(738, 242, 260, 56, "stability-check", "p99/p50, jitter, timeouts")
    node(738, 308, 260, 56, "anomaly-bias-detection", "regression / bias / anomaly")
    node(738, 430, 260, 58, "capability-eval", "capability.json", FILL_BLUE, BLUE)

    node(1038, 140, 270, 58, "prompt-injection", "attack success rate")
    node(1038, 214, 270, 58, "jailbreak-guardrail-bypass", "bypass rate")
    node(1038, 288, 270, 58, "harmful-content-bias", "harmful rate / illegal")
    node(1038, 430, 270, 58, "adversarial-test", "adversarial-test.json", FILL_BLUE, BLUE)

    node(1348, 180, 220, 64, "score-gate", "S_total + routing", FILL_BLUE, BLUE)
    node(1348, 270, 220, 64, "publish-artifact", "when passed=true", FILL_GREEN, GREEN)
    node(1348, 430, 220, 64, "archive-results", "finally (always)", FILL_GOLD, GOLD)

    # fetch -> three static
    parts.append(al(188, 282, 208, 149))
    parts.append(al(188, 282, 208, 219))
    parts.append(al(188, 282, 208, 289))
    # three static -> merge (down)
    parts.append(al(313, 178, 313, 430))
    parts.append(al(313, 248, 313, 430))
    parts.append(al(313, 318, 313, 430))
    # stage merges left to right
    parts.append(al(418, 459, 448, 459))
    parts.append(al(698, 459, 738, 459))
    parts.append(al(998, 459, 1038, 459))
    parts.append(al(1308, 459, 1348, 212))
    parts.append(al(1458, 244, 1458, 270))

    parts.append(T(32, 530, "Each column: siblings runAfter the previous merge. Merge tasks always succeed (concat JSON to MinIO scan-result/).", 12, MUTED))
    parts.append(T(32, 552, "score-gate fails the PipelineRun only when routing=reject. archive-results is pipeline finally and always writes manifest.json.", 12, MUTED))
    parts.append(T(32, 574, "Workspaces: shared-data = eval-workspace PVC (weights). results = emptyDir per TaskRun, then mc cp to s3://models-eval/<id>/<ver>/scan-result/.", 12, MUTED))

    # legend
    parts.append(R(32, 600, 16, 16, FILL_BLUE, BLUE, 1, 3))
    parts.append(T(54, 613, "Scored / merge", 12, INK))
    parts.append(R(180, 600, 16, 16, FILL_RED, RED, 1, 3))
    parts.append(T(202, 613, "Hard gate (not in S_total)", 12, INK))
    parts.append(R(420, 600, 16, 16, FILL_GREEN, GREEN, 1, 3))
    parts.append(T(442, 613, "Conditional publish", 12, INK))
    parts.append(R(620, 600, 16, 16, FILL_GOLD, GOLD, 1, 3))
    parts.append(T(642, 613, "finally", 12, INK))

    return wrap(1600, 660, "\n".join(parts), "Tekton pipeline DAG for model-security-pipeline")


def zones_network() -> str:
    parts = [arrow_def()]
    parts.append(T(40, 40, "Zone isolation  |  NetworkPolicy default-deny", 18, INK, "700"))
    parts.append(T(40, 62, "Same-namespace, DNS, ClusterIP 172.30.0.0/16, internal registry, MinIO :9000 are common.", 12, MUTED))

    # internet
    parts.append(box(40, 90, 200, 70, "Internet / HF Hub", "HTTPS :443", FILL_RED, RED))
    parts.append(box(40, 180, 200, 70, "Quay / Cosign", "Scanner images, attestations", FILL_GRAY, STROKE))

    parts.append(Rdash(280, 90, 280, 280, WHITE, RED, 2, 10))
    parts.append(T(300, 118, "model-ingress", 15, RED, "700"))
    parts.append(T(300, 138, "Untrusted intake", 12, MUTED))
    parts.append(box(300, 156, 240, 56, "Fetch Job + Envoy", "HF download allowed"))
    parts.append(box(300, 224, 240, 56, "Extra egress", "0.0.0.0/0 :443", FILL_RED, RED))
    parts.append(T(300, 304, "No eval-zone trust.", 11, MUTED))

    parts.append(R(590, 90, 320, 280, WHITE, BLUE, 2, 10))
    parts.append(T(610, 118, "model-eval", 15, BLUE, "700"))
    parts.append(T(610, 138, "Pipeline sandbox", 12, MUTED))
    parts.append(box(610, 156, 280, 56, "Tekton Tasks + score-gate", "restricted SCC"))
    parts.append(box(610, 224, 280, 56, "Extra egress", "ingress zone, Pipelines, MR, :443", FILL_BLUE, BLUE))
    parts.append(T(610, 304, "No HF Hub (weights via MinIO).", 11, MUTED))

    parts.append(Rdash(940, 90, 280, 280, WHITE, GREEN, 2, 10))
    parts.append(T(960, 118, "model-test", 15, GREEN, "700"))
    parts.append(T(960, 138, "OpenShift AI serving", 12, MUTED))
    parts.append(box(960, 156, 240, 56, "KServe + vLLM", "ingress from openshift-ingress", FILL_GREEN, GREEN))
    parts.append(box(960, 224, 240, 56, "Extra egress", ":443 (Quay). Not HF Hub."))
    parts.append(T(960, 304, "Only auto-pass models.", 11, MUTED))

    parts.append(box(1260, 160, 160, 140, "model-prod", "Later. Manual. Not a pipeline output.", FILL_GRAY, STROKE))

    # shared services
    parts.append(T(40, 400, "Shared services (not a security zone)", 14, INK, "700"))
    parts.append(box(40, 420, 280, 80, "minio-system :9000", "models-ingress, models-eval, models-verified, attestations", FILL_GRAY, STROKE))
    parts.append(box(340, 420, 260, 80, "build-image", "BuildConfigs. No zone NetworkPolicy.", FILL_GRAY, STROKE))
    parts.append(box(620, 420, 280, 80, "rhoai-model-registries", "Eval publish POST :8080 / :8443", FILL_BLUE, BLUE))
    parts.append(box(920, 420, 280, 80, "openshift-dns / registry", "All zones: DNS + image pull :443", FILL_GRAY, STROKE))
    parts.append(box(1220, 420, 200, 80, "Kata (target)", "dynamic-scan RuntimeClass later", FILL_RED, RED))

    parts.append(al(240, 125, 280, 200))
    parts.append(al(560, 230, 590, 230))
    parts.append(al(910, 230, 940, 230))
    parts.append(T(40, 540, "Eval may reach ingress namespace (artifact sync). Test must not reach Hugging Face. Catch-all :443 ipBlocks are the Quay/TLS hole to pin later.", 12, MUTED))
    parts.append(T(40, 562, "Dynamic-scan pods: tighter intent (DNS only during probe). Today RUNTIME_CLASS=kata is env; podTemplate.runtimeClassName is not set.", 12, MUTED))

    return wrap(1440, 600, "\n".join(parts), "OpenShift zone NetworkPolicy map")


def storage_flow() -> str:
    parts = [arrow_def()]
    parts.append(T(40, 40, "Storage flow  |  weights vs scan JSON", 18, INK, "700"))
    parts.append(T(40, 62, "Version = last five characters of PipelineRun name (model-security-9x57m -> 9x57m).", 12, MUTED))

    node_w = 240
    y = 100
    items = [
        (40, y, "1. Hugging Face / vendor", "hf://org/model", FILL_RED, RED),
        (320, y, "2. models-ingress", "s3://models-ingress/<id>/", FILL_RED, RED),
        (600, y, "3. eval-workspace PVC", "/models  (weights only)", FILL_BLUE, BLUE),
        (880, y, "4. models-eval scan-result", "s3://models-eval/<id>/<ver>/", FILL_BLUE, BLUE),
        (1160, y, "5. score.json", "routing auto-pass/review/reject", FILL_GOLD, GOLD),
    ]
    for x, yy, t, s, f, st in items:
        parts.append(box(x, yy, node_w, 80, t, s, f, st))
    for x in (280, 560, 840, 1120):
        parts.append(al(x, y + 40, x + 40, y + 40))

    parts.append(T(40, 220, "On auto-pass or review", 14, GREEN, "700"))
    parts.append(box(40, 240, 320, 80, "6. models-verified", "s3://models-verified/<id>/<ver>/  weights", FILL_GREEN, GREEN))
    parts.append(box(400, 240, 320, 80, "7. Model Registry", "POST registered_models + URIs", FILL_GREEN, GREEN))
    parts.append(box(760, 240, 320, 80, "8. GitOps LLMInferenceService", "model-test KServe + vLLM", FILL_GREEN, GREEN))
    parts.append(box(1120, 240, 280, 80, "always: manifest.json", "archive-results finally", FILL_GOLD, GOLD))
    parts.append(al(360, 280, 400, 280))
    parts.append(al(720, 280, 760, 280))

    parts.append(T(40, 360, "Scan-result objects (not on the PVC)", 14, INK, "700"))
    rows = [
        "static-malware.json  |  static-vulnerabilities.json  |  static-license-compliance.json  ->  static-scan.json",
        "dynamic-isolated-runtime.json  |  dynamic-behavior.json  |  dynamic-abnormal-resources.json  |  dynamic-basic-inference.json  ->  dynamic-scan.json",
        "capability-quality.json  |  capability-performance-cost.json  |  capability-stability.json  |  capability-anomaly-bias.json  ->  capability.json",
        "adversarial-prompt-injection.json  |  adversarial-jailbreak-*.json  |  adversarial-harmful-*.json  ->  adversarial-test.json",
        "score.json   publish.json   manifest.json",
    ]
    yy = 380
    for line_s in rows:
        parts.append(R(40, yy, 1360, 36, FILL_GRAY, STROKE, 1, 4))
        parts.append(T(52, yy + 24, line_s, 12, INK))
        yy += 44

    parts.append(T(40, 620, "Buckets (anonymous=none): models-ingress, models-eval, models-verified, attestations. Scanner images live in the image registry / Quay, not MinIO.", 12, MUTED))
    return wrap(1440, 660, "\n".join(parts), "MinIO and PVC storage flow")


def score_gate() -> str:
    parts = [arrow_def()]
    parts.append(T(40, 40, "Score gate  |  builds/score-gate/policy.json", 18, INK, "700"))
    parts.append(T(40, 62, "S_total = 0.40*S_static + 0.35*S_capability + 0.25*S_redteam. Dynamic-scan is a hard gate, not a weight.", 12, MUTED))

    parts.append(box(40, 90, 280, 120, "S_static  (40%)", "Start 100. Subtract CVE, license, ModelAudit, Fickling, ModelScan, Magika. Caps apply.", FILL_BLUE, BLUE))
    parts.append(box(340, 90, 280, 120, "S_capability  (35%)", "Start 100. Per-risk: crit 25, high 12, med 6, low 2.", FILL_BLUE, BLUE))
    parts.append(box(640, 90, 280, 120, "S_redteam  (25%)", "Start 100. Per-risk: crit 65, high 15, med 8, low 3.", FILL_BLUE, BLUE))
    parts.append(box(940, 90, 280, 120, "Dynamic hard gate", "critical or high in dynamic-scan.json => reject. Not in S_total.", FILL_RED, RED))

    parts.append(al(180, 210, 180, 250))
    parts.append(al(480, 210, 480, 250))
    parts.append(al(780, 210, 780, 250))
    parts.append(al(1080, 210, 1080, 250))

    parts.append(R(40, 250, 1180, 70, FILL_GRAY, STROKE, 1, 8))
    parts.append(T(60, 280, "score-gate downloads scan-result/*.json, writes score.json, uploads. Exits 1 only when routing=reject (after the file is written).", 13, INK, "600"))
    parts.append(T(60, 302, "publish-artifact when routing is auto-pass or review.", 12, MUTED))

    parts.append(R(40, 350, 380, 140, GREEN, GREEN, 0, 8))
    parts.append(T(230, 400, ">= 75   Auto-pass", 20, "#fff", "700", "middle"))
    parts.append(T(230, 430, "Pipeline succeeded. Publish + register.", 13, "#fff", "400", "middle"))
    parts.append(T(230, 454, "GitOps may serve in model-test.", 12, "#fff", "400", "middle"))

    parts.append(R(440, 350, 380, 140, GOLD, GOLD, 0, 8))
    parts.append(T(630, 400, "55-74   Review", 20, INK, "700", "middle"))
    parts.append(T(630, 430, "Pipeline succeeded. Publish + register.", 13, INK, "400", "middle"))
    parts.append(T(630, 454, "Human review flag on registry.", 12, INK, "400", "middle"))

    parts.append(R(840, 350, 380, 140, RED, RED, 0, 8))
    parts.append(T(1030, 392, "< 55  or  hard gate", 18, "#fff", "700", "middle"))
    parts.append(T(1030, 420, "or missing required JSON", 14, "#fff", "400", "middle"))
    parts.append(T(1030, 448, "Pipeline failed. Stay quarantined.", 13, "#fff", "400", "middle"))

    parts.append(T(40, 530, "License needle: missing/copyleft -40 => S_static=60 => S_total=84 (auto-pass). Deny AGPL/SSPL/NC -80 => S_static=20 => S_total=68 (review).", 12, MUTED))
    parts.append(T(40, 552, "Immediate-fail (Task, not only score): ModelAudit exec/eval/os.system/pickle, ClamAV FOUND, tool missing / empty SBOM.", 12, MUTED))
    parts.append(T(40, 574, "Known gap: missing capability/adversarial/Falco/Kepler fixtures emit [] (silent 100 / pass) on a real HF tree.", 12, MUTED))
    return wrap(1280, 620, "\n".join(parts), "Score gate formula and routing")


def gitops_promotion() -> str:
    parts = [arrow_def()]
    parts.append(T(40, 40, "Promotion  |  auto-pass to model-test", 18, INK, "700"))
    parts.append(T(40, 62, "publish-artifact is the only pipeline write into verified storage and Model Registry. Production is manual.", 12, MUTED))

    steps = [
        (40, 100, FILL_BLUE, BLUE, "score-gate", "passed=true, routing=auto-pass"),
        (280, 100, FILL_GREEN, GREEN, "publish-artifact", "mc mirror weights + POST registry"),
        (520, 100, FILL_GREEN, GREEN, "models-verified", "s3://models-verified/<id>/<ver>/"),
        (760, 100, FILL_GREEN, GREEN, "Model Registry", "storage_uri + scan_uri + version"),
        (1000, 100, FILL_GREEN, GREEN, "OpenShift GitOps", "Argo CD Application"),
        (1240, 100, FILL_GREEN, GREEN, "model-test", "LLMInferenceService / vLLM"),
    ]
    for x, y, f, st, t, s in steps:
        parts.append(box(x, y, 220, 90, t, s, f, st))
    for x in (260, 500, 740, 980, 1220):
        parts.append(al(x, 145, x + 20, 145))

    parts.append(box(40, 230, 340, 90, "Reject / review", "No publish. archive-results still runs.", FILL_RED, RED))
    parts.append(box(400, 230, 340, 90, "Tekton Chains", "SLSA on PipelineRun. Cosign / KMS.", FILL_BLUE, BLUE))
    parts.append(box(760, 230, 340, 90, "model-prod", "Not a pipeline output. Manual later.", FILL_GRAY, STROKE))
    parts.append(box(1120, 230, 280, 90, "Observability", "Prometheus, Grafana, KEDA.", FILL_GRAY, STROKE))

    parts.append(T(40, 360, "GitOps manifests: instances/gitops/application-model-test.yaml + instances/model-test/llm-models/.", 12, MUTED))
    parts.append(T(40, 382, "Serving reads MinIO models-verified, not Hugging Face. Test-zone NetworkPolicy is intended to deny Hub egress.", 12, MUTED))
    return wrap(1440, 430, "\n".join(parts), "GitOps promotion from score gate to model-test")


def main() -> None:
    write("architecture-overview.svg", architecture_overview())
    write("pipeline-dag.svg", pipeline_dag())
    write("zones-network.svg", zones_network())
    write("storage-flow.svg", storage_flow())
    write("score-gate.svg", score_gate())
    write("gitops-promotion.svg", gitops_promotion())


if __name__ == "__main__":
    main()
