#!/usr/bin/env python3
"""Concatenate the four capability-eval subtask finding arrays. Always exits 0.

Looks for files at the results workspace root (downloaded from S3 scan-result/):
  capability-quality.json
  capability-performance-cost.json
  capability-stability.json
  capability-anomaly-bias.json
"""
import json
import sys
from pathlib import Path

FILES = {
    "quality": "capability-quality.json",
    "performance-cost": "capability-performance-cost.json",
    "stability-check": "capability-stability.json",
    "anomaly-bias-detection": "capability-anomaly-bias.json",
}

results = Path(sys.argv[1] if len(sys.argv) > 1 else "/results")
out = Path(sys.argv[2] if len(sys.argv) > 2 else str(results / "capability.json"))

merged = []
for subtask, filename in FILES.items():
    path = results / filename
    if not path.exists():
        nested = results / "capability-eval" / f"{subtask}.json"
        path = nested if nested.exists() else path
    if not path.exists():
        merged.append({
            "issue": f"subtask {subtask} produced no findings file",
            "risk": "critical",
            "tool_used": "capability-eval",
            "task": "capability-eval",
            "subtask": subtask,
        })
        continue
    try:
        payload = json.loads(path.read_text() or "[]")
    except (OSError, json.JSONDecodeError) as exc:
        merged.append({
            "issue": f"subtask {subtask} findings are not valid JSON: {exc}",
            "risk": "critical",
            "tool_used": "capability-eval",
            "task": "capability-eval",
            "subtask": subtask,
        })
        continue
    if isinstance(payload, dict):
        payload = payload.get("issues") or [payload]
    if isinstance(payload, list):
        merged.extend(payload)

out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(merged, indent=2) + "\n")
print(out.read_text())
sys.exit(0)
