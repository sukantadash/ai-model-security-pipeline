#!/usr/bin/env bash
# Subtask behavior: Falco/Tetragon alerts during the probe window.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-/results/dynamic-behavior.json}"
ALERTS="${2:-}"
python3 - "${OUT}" "${ALERTS}" <<'PY' | python3 "${SCRIPT_DIR}/emit_findings.py" --subtask behavior --tool falco --out "${OUT}"
import json, os, sys

_, alerts_path = sys.argv[1], sys.argv[2]
candidates = [p for p in (alerts_path, os.path.join(os.path.dirname(alerts_path or ""), "falco-alerts.json")) if p]
findings = []
path = next((p for p in candidates if p and os.path.isfile(p)), None)
# Fixture lives on unit ConfigMaps, not next to HF weights. Missing ≠ hard-gate fail.
if path is None:
    print("[]")
    raise SystemExit
else:
    try:
        payload = json.loads(open(path).read() or "[]")
    except json.JSONDecodeError:
        payload = []
        findings.append({
            "issue": "Falco alert log is not valid JSON",
            "risk": "high",
            "tool_used": "falco",
        })
    if isinstance(payload, dict):
        payload = payload.get("alerts") or payload.get("findings") or []
    for alert in payload:
        rule = alert.get("rule") or alert.get("issue") or "unknown-rule"
        findings.append({
            "issue": f"runtime behavior alert: {rule}",
            "risk": alert.get("risk", "critical"),
            "tool_used": alert.get("tool_used", "falco"),
        })
print(json.dumps(findings))
PY
