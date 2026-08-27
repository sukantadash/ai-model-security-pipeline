#!/usr/bin/env python3
"""Validate capability-eval unit-test JSON against the expected finding contract."""
from __future__ import annotations

import json
import sys
from pathlib import Path

REQUIRED_KEYS = ("issue", "risk", "tool_used", "task", "subtask")
RISKS = {"critical", "high", "medium", "low"}

CHECKS = {
    "capability-quality.json": {
        "subtask": "quality",
        "min_findings": 1,
        "issue_contains": "MMLU accuracy",
        "risk": "high",
        "tool_used": "lm-eval",
    },
    "capability-performance-cost.json": {
        "subtask": "performance-cost",
        "min_findings": 1,
        "issue_contains": "p99 latency",
        "risk": "high",
        "tool_used": "latency-probe",
    },
    "capability-stability.json": {
        "subtask": "stability-check",
        "min_findings": 1,
        "issue_contains": "sporadic slowdown",
        "risk": "high",
        "tool_used": "latency-distribution",
    },
    "capability-anomaly-bias.json": {
        "subtask": "anomaly-bias-detection",
        "min_findings": 1,
        "issue_contains": "quality regression vs baseline",
        "risk": "high",
        "tool_used": "trulens",
    },
}


def load_findings(path: Path) -> list:
    payload = json.loads(path.read_text())
    if isinstance(payload, dict):
        payload = payload.get("issues") or [payload]
    if not isinstance(payload, list):
        raise SystemExit(f"{path.name}: expected a JSON array")
    return payload


def main() -> int:
    results = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    errors: list[str] = []
    for filename, spec in CHECKS.items():
        path = results / filename
        if not path.is_file():
            errors.append(f"missing {filename}")
            continue
        findings = load_findings(path)
        if len(findings) < spec["min_findings"]:
            errors.append(f"{filename}: expected >= {spec['min_findings']} findings, got {len(findings)}")
        for row in findings:
            missing = [k for k in REQUIRED_KEYS if k not in row]
            if missing:
                errors.append(f"{filename}: missing keys {missing} in {row}")
                continue
            if row.get("task") != "capability-eval":
                errors.append(f"{filename}: task={row.get('task')!r} want capability-eval")
            if row.get("subtask") != spec["subtask"]:
                errors.append(f"{filename}: subtask={row.get('subtask')!r} want {spec['subtask']}")
            if row.get("risk") not in RISKS:
                errors.append(f"{filename}: invalid risk {row.get('risk')!r}")
        matched = [
            row
            for row in findings
            if spec["issue_contains"].lower() in str(row.get("issue", "")).lower()
            and row.get("risk") == spec["risk"]
            and row.get("tool_used") == spec["tool_used"]
        ]
        if not matched:
            errors.append(
                f"{filename}: no finding with issue containing {spec['issue_contains']!r}, "
                f"risk={spec['risk']}, tool_used={spec['tool_used']}; got {findings}"
            )
    if errors:
        print("FAIL")
        print("\n".join(errors))
        return 1
    print("PASS: capability-eval unit findings match expected schema and issues")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
