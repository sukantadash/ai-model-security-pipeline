#!/usr/bin/env python3
"""Concatenate the four dynamic-scan subtask finding arrays. Always exits 0.

Looks for files at the results workspace root (downloaded from S3 scan-result/):
  dynamic-isolated-runtime.json
  dynamic-behavior.json
  dynamic-abnormal-resources.json
  dynamic-basic-inference.json
"""
import json
import sys
from pathlib import Path

FILES = {
    "isolated-runtime": "dynamic-isolated-runtime.json",
    "behavior": "dynamic-behavior.json",
    "abnormal-resources": "dynamic-abnormal-resources.json",
    "basic-inference": "dynamic-basic-inference.json",
}


def load_issues(path: Path, subtask: str) -> list:
    try:
        payload = json.loads(path.read_text() or "[]")
    except (OSError, json.JSONDecodeError) as exc:
        return [{
            "issue": f"subtask {subtask} findings are not valid JSON: {exc}",
            "risk": "critical",
            "tool_used": "dynamic-scan",
            "task": "dynamic-scan",
            "subtask": subtask,
        }]
    if isinstance(payload, dict):
        payload = payload.get("issues") or [payload]
    return payload if isinstance(payload, list) else []


def main() -> int:
    results = Path(sys.argv[1] if len(sys.argv) > 1 else "/results")
    out = Path(sys.argv[2] if len(sys.argv) > 2 else str(results / "dynamic-scan.json"))
    merged = []
    for subtask, filename in FILES.items():
        path = results / filename
        nested = results / "dynamic-scan" / f"{subtask}.json"
        if not path.exists() and nested.exists():
            path = nested
        if not path.exists():
            merged.append({
                "issue": f"subtask {subtask} produced no findings file",
                "risk": "critical",
                "tool_used": "dynamic-scan",
                "task": "dynamic-scan",
                "subtask": subtask,
            })
            continue
        merged.extend(load_issues(path, subtask))
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(merged, indent=2) + "\n")
    print(out.read_text())
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        out = Path(sys.argv[2] if len(sys.argv) > 2 else "/results/dynamic-scan.json")
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps([{
            "issue": f"dynamic-scan merge failed: {exc}",
            "risk": "critical",
            "tool_used": "dynamic-scan",
            "task": "dynamic-scan",
            "subtask": "merge",
        }], indent=2) + "\n")
        print(out.read_text())
        raise SystemExit(0)
