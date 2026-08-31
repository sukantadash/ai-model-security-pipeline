#!/usr/bin/env bash
# Subtask behavior: Falco fixture, or sandbox pod events from SANDBOX_INSPECT_DIR.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-/results/dynamic-behavior.json}"
ALERTS="${2:-}"
python3 - "${OUT}" "${ALERTS}" <<'PY' | python3 "${SCRIPT_DIR}/emit_findings.py" --subtask behavior --tool falco --out "${OUT}"
import json, os, sys
from pathlib import Path

_, alerts_path = sys.argv[1], sys.argv[2]
candidates = [p for p in (alerts_path, os.path.join(os.path.dirname(alerts_path or ""), "falco-alerts.json")) if p]
findings = []
path = next((p for p in candidates if p and os.path.isfile(p)), None)
if path is not None:
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
    raise SystemExit

inspect_dir = (os.environ.get("SANDBOX_INSPECT_DIR") or "").strip()
if inspect_dir:
    events_path = Path(inspect_dir) / "events.json"
    # Match Event.reason only. Substring "failed"/"unhealthy" matches normal
    # startup probes and would hard-gate a healthy vLLM load.
    suspicious_reasons = {
        "oomkilled",
        "evicted",
        "crashloopbackoff",
        "backoff",
    }
    pod_names = set()
    pods_path = Path(inspect_dir) / "pods.json"
    if pods_path.is_file():
        try:
            pods_doc = json.loads(pods_path.read_text() or "{}")
        except json.JSONDecodeError:
            pods_doc = {}
        for pod in (pods_doc.get("items") if isinstance(pods_doc, dict) else []) or []:
            if isinstance(pod, dict):
                n = str((pod.get("metadata") or {}).get("name") or "")
                if n:
                    pod_names.add(n)
    if events_path.is_file():
        try:
            doc = json.loads(events_path.read_text() or "{}")
        except json.JSONDecodeError:
            doc = {}
        items = doc.get("items") if isinstance(doc, dict) else []
        for ev in items or []:
            if not isinstance(ev, dict):
                continue
            obj = str((ev.get("involvedObject") or {}).get("name") or "")
            if pod_names and obj not in pod_names:
                continue
            reason = str(ev.get("reason") or "").lower().replace(" ", "")
            if reason in suspicious_reasons or "oomkill" in reason or "crashloop" in reason:
                findings.append({
                    "issue": f"sandbox pod event: {ev.get('reason') or reason}",
                    "risk": "high",
                    "tool_used": "falco",
                })
    findings.append({
        "issue": "Falco/Tetragon not collecting on the sandbox serving pod; scored pod events only",
        "risk": "medium",
        "tool_used": "falco",
    })
    print(json.dumps(findings))
    raise SystemExit

# Unit / no inspect / no fixture: silent pass (fixtures live on ConfigMaps).
print("[]")
PY
