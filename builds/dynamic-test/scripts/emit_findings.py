#!/usr/bin/env python3
"""Write dynamic-scan subtask findings in the shared issue schema.

Subtask TaskRuns always persist JSON and exit 0 (same as static-scan).
Merge and score-gate also exit 0 so findings stay on the PVC; publish is gated on passed.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

TASK = "dynamic-scan"
RISKS = ("critical", "high", "medium", "low")
SUBTASKS = (
    "isolated-runtime",
    "behavior",
    "abnormal-resources",
    "basic-inference",
)


def normalize(row: dict[str, Any], subtask: str, tool_used: str) -> dict[str, str]:
    risk = str(row.get("risk", "medium")).strip().lower()
    if risk not in RISKS:
        risk = "medium"
    issue = str(row.get("issue") or row.get("Issue") or "").strip()
    tool = str(row.get("tool_used") or row.get("tool used") or tool_used)
    return {
        "issue": issue,
        "risk": risk,
        "tool_used": tool,
        "task": TASK,
        "subtask": str(row.get("subtask") or subtask),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--subtask", required=True, choices=SUBTASKS)
    parser.add_argument("--tool", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument(
        "--fail-on",
        default="",
        help="comma-separated risks that fail the process; empty = always exit 0",
    )
    args = parser.parse_args()
    raw = sys.stdin.read().strip() or "[]"
    payload = json.loads(raw)
    if isinstance(payload, dict):
        payload = [payload]
    findings = [normalize(row, args.subtask, args.tool) for row in payload if row]
    findings = [row for row in findings if row["issue"]]
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(findings, indent=2) + "\n")
    print(out.read_text())
    fail_on = {r.strip().lower() for r in args.fail_on.split(",") if r.strip()}
    if fail_on and any(row["risk"] in fail_on for row in findings):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
