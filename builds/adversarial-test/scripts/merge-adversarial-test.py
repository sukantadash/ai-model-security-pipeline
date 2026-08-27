#!/usr/bin/env python3
"""Concatenate the three adversarial-test subtask finding arrays. Always exits 0.

Looks for files at the results workspace root (downloaded from S3 scan-result/):
  adversarial-prompt-injection.json
  adversarial-jailbreak-guardrail-bypass.json
  adversarial-harmful-content-bias.json
"""
import json
import sys
from pathlib import Path

FILES = {
    "prompt-injection": "adversarial-prompt-injection.json",
    "jailbreak-guardrail-bypass": "adversarial-jailbreak-guardrail-bypass.json",
    "harmful-content-bias": "adversarial-harmful-content-bias.json",
}

results = Path(sys.argv[1] if len(sys.argv) > 1 else "/results")
out = Path(sys.argv[2] if len(sys.argv) > 2 else str(results / "adversarial-test.json"))

merged = []
for subtask, filename in FILES.items():
    path = results / filename
    if not path.exists():
        nested = results / "adversarial-test" / f"{subtask}.json"
        path = nested if nested.exists() else path
    if not path.exists():
        merged.append({
            "issue": f"subtask {subtask} produced no findings file",
            "risk": "critical",
            "tool_used": "adversarial-test",
            "task": "adversarial-test",
            "subtask": subtask,
        })
        continue
    try:
        payload = json.loads(path.read_text() or "[]")
    except (OSError, json.JSONDecodeError) as exc:
        merged.append({
            "issue": f"subtask {subtask} findings are not valid JSON: {exc}",
            "risk": "critical",
            "tool_used": "adversarial-test",
            "task": "adversarial-test",
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
