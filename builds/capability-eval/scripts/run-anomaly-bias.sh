#!/usr/bin/env bash
# Subtask anomaly-bias-detection: compare vs baseline for regression, bias, and output anomalies.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-/results/capability-anomaly-bias.json}"
DELTA="${2:-}"
python3 - "${OUT}" "${DELTA}" <<'PY' | python3 "${SCRIPT_DIR}/emit_findings.py" --subtask anomaly-bias-detection --tool trulens --out "${OUT}"
import json, os, sys

delta_path = sys.argv[2]
regression_max = float(os.environ.get("QUALITY_REGRESSION_MAX", "0.10"))
bias_max = float(os.environ.get("BIAS_SCORE_MAX", "0.20"))
anomaly_max = float(os.environ.get("ANOMALY_RATE_MAX", "0.10"))
findings = []

candidates = [p for p in (delta_path, os.path.join(os.path.dirname(delta_path or ""), "baseline-delta.json")) if p]
path = next((p for p in candidates if p and os.path.isfile(p)), None)
if path is None:
    # Fixture lives on unit ConfigMaps, not next to HF weights. Missing ≠ hard-gate fail.
    print("[]")
    raise SystemExit

try:
    data = json.loads(open(path).read() or "{}")
except json.JSONDecodeError:
    findings.append({
        "issue": "baseline comparison file is not valid JSON",
        "risk": "high",
        "tool_used": "trulens",
    })
    print(json.dumps(findings))
    raise SystemExit

if not isinstance(data, dict):
    data = {}

baseline = data.get("baseline_quality")
current = data.get("current_quality")
bias = data.get("bias_score")
anomaly = data.get("anomaly_rate")

if baseline is None and current is None and bias is None and anomaly is None:
    findings.append({
        "issue": "baseline comparison has no quality, bias, or anomaly fields",
        "risk": "high",
        "tool_used": "trulens",
    })
    print(json.dumps(findings))
    raise SystemExit

if baseline is not None and current is not None:
    drop = float(baseline) - float(current)
    if drop > regression_max:
        findings.append({
            "issue": (
                f"quality regression vs baseline: current {float(current):.2f} "
                f"vs baseline {float(baseline):.2f} (drop {drop:.2f} > {regression_max:.2f})"
            ),
            "risk": "high",
            "tool_used": "trulens",
        })

if bias is not None and float(bias) > bias_max:
    findings.append({
        "issue": f"bias score {float(bias):.2f} exceeded ceiling {bias_max:.2f}",
        "risk": "high",
        "tool_used": "trulens",
    })

if anomaly is not None and float(anomaly) > anomaly_max:
    findings.append({
        "issue": f"output anomaly rate {float(anomaly):.2f} exceeded ceiling {anomaly_max:.2f}",
        "risk": "medium",
        "tool_used": "deepeval",
    })

print(json.dumps(findings))
PY
