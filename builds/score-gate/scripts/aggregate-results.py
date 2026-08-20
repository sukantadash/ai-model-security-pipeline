#!/usr/bin/env python3
"""Aggregate Tekton task JSON results into a pass/fail score (fail-closed)."""
import json
import sys
from pathlib import Path

REQUIRED = ("static", "dynamic-probe", "dynamic-gpu", "capability", "redteam")

results_dir = Path(sys.argv[1] if len(sys.argv) > 1 else "/results")
out = Path(sys.argv[2] if len(sys.argv) > 2 else "/results/score.json")

scores = {}
for path in sorted(results_dir.glob("*.json")):
    if path.name in ("score.json", "publish.json", "publish.log"):
        continue
    scores[path.stem] = json.loads(path.read_text())

missing = [name for name in REQUIRED if name not in scores]
failed = [name for name in REQUIRED if scores.get(name, {}).get("status") != "pass"]
passed = not missing and not failed

summary = {
    "passed": passed,
    "missing": missing,
    "failed": failed,
    "scores": scores,
}
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(summary, indent=2))
print(json.dumps(summary))
sys.exit(0 if passed else 1)
