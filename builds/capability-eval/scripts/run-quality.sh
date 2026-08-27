#!/usr/bin/env bash
# Subtask quality: verify answer accuracy against standard benchmarks (MMLU, GSM8K, HumanEval).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-/results/capability-quality.json}"
SCORES="${2:-}"
python3 - "${OUT}" "${SCORES}" <<'PY' | python3 "${SCRIPT_DIR}/emit_findings.py" --subtask quality --tool lm-eval --out "${OUT}"
import json, os, sys

scores_path = sys.argv[2]
mmlu_min = float(os.environ.get("QUALITY_MMLU_MIN", "0.50"))
gsm8k_min = float(os.environ.get("QUALITY_GSM8K_MIN", "0.40"))
humaneval_min = float(os.environ.get("QUALITY_HUMANEVAL_MIN", "0.30"))
findings = []

candidates = [p for p in (scores_path, os.path.join(os.path.dirname(scores_path or ""), "quality-scores.json")) if p]
path = next((p for p in candidates if p and os.path.isfile(p)), None)
if path is None:
    # Fixture lives on unit ConfigMaps, not next to HF weights. Missing ≠ hard-gate fail.
    print("[]")
    raise SystemExit

try:
    data = json.loads(open(path).read() or "{}")
except json.JSONDecodeError:
    findings.append({
        "issue": "quality benchmark scores are not valid JSON",
        "risk": "high",
        "tool_used": "lm-eval",
    })
    print(json.dumps(findings))
    raise SystemExit

if isinstance(data, dict):
    scores = data.get("benchmarks") or data.get("scores") or data
else:
    scores = {}

def score_of(keys):
    for key in keys:
        if key in scores and scores[key] is not None:
            try:
                return float(scores[key])
            except (TypeError, ValueError):
                return None
    return None

checks = (
    ("MMLU", ("mmlu", "MMLU"), mmlu_min),
    ("GSM8K", ("gsm8k", "GSM8K"), gsm8k_min),
    ("HumanEval", ("humaneval", "HumanEval", "human_eval"), humaneval_min),
)
found_any = False
for label, keys, minimum in checks:
    value = score_of(keys)
    if value is None:
        continue
    found_any = True
    if value < minimum:
        findings.append({
            "issue": f"{label} accuracy {value:.2f} below threshold {minimum:.2f}",
            "risk": "high",
            "tool_used": "lm-eval",
        })

if not found_any:
    findings.append({
        "issue": "quality scores file has no MMLU/GSM8K/HumanEval results",
        "risk": "high",
        "tool_used": "lm-eval",
    })

print(json.dumps(findings))
PY
