#!/usr/bin/env python3
"""Compute S_total from stage finding JSON and write score.json.

S_static starts at 100 and subtracts policy penalties.
S_total = 0.40 × S_static + 0.35 × S_capability + 0.25 × S_redteam
Dynamic-scan is a hard gate (not in the weight). Always exits 0; the Task
fails the PipelineRun on routing=reject after results are written.
"""
from __future__ import annotations

import json
import os
import re
import sys
from collections import defaultdict
from pathlib import Path

POLICY_PATH = os.environ.get("SCORE_GATE_POLICY", "/etc/score-gate/policy.json")
SKIP_FILES = {"score.json", "publish.json", "publish.log", "manifest.json"}

STATIC_FILES = (
    "static-malware",
    "static-vulnerabilities",
    "static-license-compliance",
    "static-scan",
)
REQUIRED = (
    ("static", STATIC_FILES),
    ("dynamic", ("dynamic-scan",)),
    ("capability", ("capability", "capability-eval")),
    ("redteam", ("adversarial-test", "redteam")),
)


def load_policy() -> dict:
    path = Path(POLICY_PATH)
    if not path.exists():
        path = Path(__file__).resolve().parent.parent / "policy.json"
    return json.loads(path.read_text())


def issues_from(doc) -> list:
    if isinstance(doc, list):
        return [row for row in doc if isinstance(row, dict)]
    if isinstance(doc, dict):
        if isinstance(doc.get("issues"), list):
            return [row for row in doc["issues"] if isinstance(row, dict)]
        if "issue" in doc:
            return [doc]
    return []


def load_docs(results_dir: Path) -> dict:
    docs = {}
    for path in sorted(results_dir.glob("*.json")):
        if path.name in SKIP_FILES:
            continue
        try:
            docs[path.stem] = json.loads(path.read_text())
        except json.JSONDecodeError:
            docs[path.stem] = {"status": "fail", "issues": [], "error": "invalid json"}
    return docs


def first_doc(docs: dict, stems: tuple[str, ...]):
    for stem in stems:
        if stem in docs:
            return stem, docs[stem]
    return None, None


def tool_of(row: dict) -> str:
    return str(row.get("tool") or row.get("tool_used") or "").lower()


def risk_of(row: dict) -> str:
    return str(row.get("risk") or "").lower()


def text_of(row: dict) -> str:
    return str(row.get("issue") or "").lower()


MODELAUDIT_IMMEDIATE_RE = re.compile(
    r"(\bexec\s*\(|\beval\s*\(|os\.system|posix\.system|\bsubprocess\b|__reduce__|pickle\.loads)",
    re.I,
)


def is_immediate_fail(row: dict, policy: dict) -> bool:
    if row.get("immediate_fail") is True:
        return True
    tool = tool_of(row)
    risk = risk_of(row)
    text = str(row.get("issue") or "")
    needles = policy.get("immediate_fail") or {}
    if tool == "clamav" and risk == "critical":
        return True
    if tool == "modelaudit" and risk == "critical":
        return bool(MODELAUDIT_IMMEDIATE_RE.search(text))
    if risk == "critical" and any(n.lower() in text.lower() for n in needles.get("tool_missing_needles") or []):
        return True
    return False


def apply_caps(bucket_sums: dict[str, float], policy: dict) -> float:
    penalties = policy["penalties"]
    caps = {
        "modelaudit_warning": penalties.get("modelaudit_warning_cap"),
        "fickling_unlisted_import": penalties.get("fickling_cap"),
        "modelscan": penalties.get("modelscan_cap"),
        "cve_critical": penalties.get("cve_critical_cap"),
        "cve_high": penalties.get("cve_high_cap"),
    }
    modelscan = bucket_sums.get("modelscan_critical", 0) + bucket_sums.get("modelscan_high", 0)
    total = 0.0
    for key, value in bucket_sums.items():
        if key in ("modelscan_critical", "modelscan_high"):
            continue
        cap = caps.get(key)
        total += min(value, cap) if cap is not None else value
    cap = caps["modelscan"]
    total += min(modelscan, cap) if cap is not None else modelscan
    return total


def classify_static(row: dict, policy: dict) -> tuple[str, float | str]:
    penalties = policy["penalties"]
    if is_immediate_fail(row, policy):
        return "immediate_fail", "immediate_fail"
    tool = tool_of(row)
    risk = risk_of(row)
    text = text_of(row)
    if tool == "modelaudit":
        if risk in ("critical", "high"):
            return "modelaudit_critical", penalties["modelaudit_critical"]
        return "modelaudit_warning", penalties["modelaudit_warning"]
    if tool == "fickling":
        return "fickling_unlisted_import", penalties["fickling_unlisted_import"]
    if tool == "modelscan":
        if risk == "critical":
            return "modelscan_critical", penalties["modelscan_critical"]
        return "modelscan_high", penalties["modelscan_high"]
    if tool == "magika":
        return "magika_native_executable", penalties["magika_native_executable"]
    if tool in ("grype", "syft") or text.startswith("cve") or " ghsa-" in f" {text}":
        key = f"cve_{risk}" if f"cve_{risk}" in penalties else "cve_medium"
        return key, penalties[key]
    if tool in ("license-files", "license") or "license" in text:
        if risk == "critical" or "denied" in text:
            return "license_deny", penalties["license_deny"]
        if "no oss license" in text or "missing" in text:
            return "license_missing", penalties["license_missing"]
        if "copyleft" in text:
            return "license_copyleft", penalties["license_copyleft"]
        return "license_unlisted", penalties["license_unlisted"]
    if risk == "critical":
        return "unclassified_critical", penalties.get("modelaudit_critical", 25)
    if risk == "high":
        return "unclassified_high", penalties.get("cve_high", 10)
    if risk == "medium":
        return "unclassified_medium", penalties.get("cve_medium", 5)
    return "unclassified_low", penalties.get("cve_low", 2)


def score_from_issues(issues: list, table: dict, start: float = 100.0) -> tuple[float, list]:
    applied = []
    deducted = 0.0
    for row in issues:
        risk = risk_of(row)
        amount = float(table.get(risk, 0))
        if amount:
            deducted += amount
            applied.append({"issue": row.get("issue"), "risk": risk, "penalty": amount})
    return max(0.0, min(100.0, start - deducted)), applied


def numeric_score(doc) -> float | None:
    if isinstance(doc, dict) and isinstance(doc.get("score"), (int, float)):
        return max(0.0, min(100.0, float(doc["score"])))
    return None


def score_static(issues: list, policy: dict) -> dict:
    start = float(policy.get("scoring", {}).get("start", 100))
    fail_score = float(policy.get("scoring", {}).get("immediate_fail_sets_score", 0))
    buckets: dict[str, float] = defaultdict(float)
    applied = []
    immediate = []
    for row in issues:
        key, amount = classify_static(row, policy)
        if amount == "immediate_fail":
            immediate.append(row)
            applied.append({"issue": row.get("issue"), "tool": tool_of(row), "penalty": "immediate_fail"})
            continue
        buckets[key] += float(amount)
        applied.append({"issue": row.get("issue"), "tool": tool_of(row), "penalty": amount, "family": key})
    if immediate:
        return {
            "score": fail_score,
            "immediate_fail": True,
            "penalties": applied,
            "immediate_fail_issues": immediate,
        }
    deducted = apply_caps(buckets, policy)
    return {
        "score": max(0.0, min(100.0, start - deducted)),
        "immediate_fail": False,
        "penalties": applied,
        "immediate_fail_issues": [],
    }


def route_for(total: float, policy: dict) -> str:
    auto_pass = float(policy["thresholds"]["auto_pass"])
    review = float(policy["thresholds"]["review"])
    if total >= auto_pass:
        return "auto-pass"
    if total >= review:
        return "review"
    return "reject"


def gather_static_issues(docs: dict) -> list:
    issues = []
    seen = set()
    merged_stem, merged = first_doc(docs, ("static-scan",))
    if merged is not None:
        for row in issues_from(merged):
            marker = json.dumps(row, sort_keys=True)
            if marker not in seen:
                seen.add(marker)
                issues.append(row)
        if issues:
            return issues
    for stem in ("static-malware", "static-vulnerabilities", "static-license-compliance"):
        issues.extend(issues_from(docs.get(stem)))
    return issues


def main() -> int:
    results_dir = Path(sys.argv[1] if len(sys.argv) > 1 else "/results")
    out = Path(sys.argv[2] if len(sys.argv) > 2 else str(results_dir / "score.json"))
    policy = load_policy()
    docs = load_docs(results_dir)
    weights = policy["weights"]

    missing = []
    for label, stems in REQUIRED:
        stem, _doc = first_doc(docs, stems)
        if stem is not None:
            continue
        if label == "static":
            have = [
                name
                for name in ("static-malware", "static-vulnerabilities", "static-license-compliance")
                if name in docs
            ]
            if len(have) == 3:
                continue
        missing.append(label)

    static_issues = gather_static_issues(docs)
    static_result = score_static(static_issues, policy)
    s_static = static_result["score"]

    cap_stem, cap_doc = first_doc(docs, ("capability", "capability-eval"))
    red_stem, red_doc = first_doc(docs, ("adversarial-test", "redteam"))
    dyn_stem, dyn_doc = first_doc(docs, ("dynamic-scan",))

    s_capability = numeric_score(cap_doc)
    cap_applied = []
    if s_capability is None:
        s_capability, cap_applied = score_from_issues(
            issues_from(cap_doc), policy["capability_penalties"], policy["scoring"]["start"]
        )

    s_redteam = numeric_score(red_doc)
    red_applied = []
    if s_redteam is None:
        s_redteam, red_applied = score_from_issues(
            issues_from(red_doc), policy["redteam_penalties"], policy["scoring"]["start"]
        )

    s_total = (
        weights["static"] * s_static
        + weights["capability"] * s_capability
        + weights["redteam"] * s_redteam
    )
    s_total = round(s_total, 2)

    hard_failed = []
    dyn_risks = {r.lower() for r in policy.get("dynamic_hard_gate_risks") or ["critical", "high"]}
    if dyn_doc is None:
        hard_failed.append("dynamic-scan")
    else:
        if isinstance(dyn_doc, dict) and dyn_doc.get("status") not in (None, "pass"):
            hard_failed.append("dynamic-scan")
        elif any(risk_of(row) in dyn_risks for row in issues_from(dyn_doc)):
            hard_failed.append("dynamic-scan")

    routing = route_for(s_total, policy)
    reasons = []
    if missing:
        routing = "reject"
        reasons.append(f"missing stage JSON: {', '.join(missing)}")
    if hard_failed:
        routing = "reject"
        reasons.append("dynamic-scan hard gate failed")
    if static_result["immediate_fail"]:
        routing = "reject"
        reasons.append("static-scan immediate fail (ModelAudit exec/eval, ClamAV, or required tool missing)")
        s_static = float(policy["scoring"]["immediate_fail_sets_score"])
        s_total = round(
            weights["static"] * s_static
            + weights["capability"] * s_capability
            + weights["redteam"] * s_redteam,
            2,
        )

    passed = routing == "auto-pass"
    summary = {
        "passed": passed,
        "routing": routing,
        "score": s_total,
        "S_total": s_total,
        "S_static": round(s_static, 2),
        "S_capability": round(s_capability, 2),
        "S_redteam": round(s_redteam, 2),
        "weights": weights,
        "formula": "S_total = 0.40 × S_static + 0.35 × S_capability + 0.25 × S_redteam",
        "thresholds": policy["thresholds"],
        "missing": missing,
        "hard_gate_failed": hard_failed,
        "reasons": reasons,
        "static": static_result,
        "capability_penalties": cap_applied,
        "redteam_penalties": red_applied,
        "sources": {
            "static": [s for s in STATIC_FILES if s in docs],
            "dynamic": dyn_stem,
            "capability": cap_stem,
            "redteam": red_stem,
        },
    }
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(summary, indent=2, default=str) + "\n")
    print(
        json.dumps(
            {
                "passed": passed,
                "routing": routing,
                "S_total": s_total,
                "S_static": summary["S_static"],
                "S_capability": summary["S_capability"],
                "S_redteam": summary["S_redteam"],
                "missing": missing,
                "hard_gate_failed": hard_failed,
                "reasons": reasons,
            }
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
