#!/usr/bin/env python3
"""Concatenate the three static-scan subtask finding files. Always exits 0."""
import json
import sys
from pathlib import Path

FILES = {
    "malware": "static-malware.json",
    "vulnerabilities": "static-vulnerabilities.json",
    "license-compliance": "static-license-compliance.json",
}

results = Path(sys.argv[1] if len(sys.argv) > 1 else "/results")
out = Path(sys.argv[2] if len(sys.argv) > 2 else str(results / "static-scan.json"))

merged = []
for subtask, filename in FILES.items():
    path = results / filename
    if not path.exists():
        merged.append({
            "issue": f"subtask {subtask} produced no findings file",
            "risk": "critical",
            "tool": "static-scan-merge",
            "task": "static-scan",
            "subtask": subtask,
        })
        continue
    payload = json.loads(path.read_text() or "{}")
    if isinstance(payload, dict):
        issues = payload.get("issues") or []
    elif isinstance(payload, list):
        issues = payload
    else:
        issues = []
    merged.extend(issues)

out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(merged, indent=2) + "\n")
print(out.read_text())
sys.exit(0)
