#!/usr/bin/env bash
# Subtask quality: live LLMInferenceService prompts or unit fixture scores.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-/results/capability-quality.json}"
SCORES="${2:-}"
export SCRIPT_DIR
python3 - "${OUT}" "${SCORES}" <<'PY' | python3 "${SCRIPT_DIR}/emit_findings.py" --subtask quality --tool lm-eval --out "${OUT}"
import json, os, sys
sys.path.insert(0, os.environ.get("SCRIPT_DIR", "/scripts"))

scores_path = sys.argv[2]
mmlu_min = float(os.environ.get("QUALITY_MMLU_MIN", "0.50"))
gsm8k_min = float(os.environ.get("QUALITY_GSM8K_MIN", "0.40"))
humaneval_min = float(os.environ.get("QUALITY_HUMANEVAL_MIN", "0.30"))
findings = []
endpoint = (os.environ.get("MODEL_ENDPOINT") or "").strip()
scores = {}

def score_findings(scores):
    out = []
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
            out.append({
                "issue": f"{label} accuracy {value:.2f} below threshold {minimum:.2f}",
                "risk": "high",
                "tool_used": "lm-eval",
            })
    if not found_any:
        out.append({
            "issue": "quality scores file has no MMLU/GSM8K/HumanEval results",
            "risk": "high",
            "tool_used": "lm-eval",
        })
    return out

if endpoint:
    import vllm_client
    prompt_file = os.path.join(os.environ.get("SCRIPT_DIR", "/scripts"), "live-prompts.json")
    prompts = []
    if os.path.isfile(prompt_file):
        try:
            blob = json.loads(open(prompt_file).read() or "{}")
            prompts = blob.get("prompts") or []
        except json.JSONDecodeError:
            findings.append({
                "issue": "live quality prompts are not valid JSON",
                "risk": "high",
                "tool_used": "lm-eval",
            })
            print(json.dumps(findings))
            raise SystemExit
    hits = {"mmlu": [], "gsm8k": [], "humaneval": []}
    if not prompts:
        findings.append({
            "issue": "quality scores file has no MMLU/GSM8K/HumanEval results",
            "risk": "high",
            "tool_used": "lm-eval",
        })
        print(json.dumps(findings))
        raise SystemExit
    for item in prompts:
        bench = str(item.get("benchmark") or "mmlu").lower()
        result = vllm_client.chat(endpoint, item.get("prompt") or "ping", max_tokens=16, timeout=120)
        if not result.get("ok"):
            findings.append({
                "issue": f"llm endpoint unreachable: {result.get('error')}",
                "risk": "critical",
                "tool_used": "lm-eval",
            })
            print(json.dumps(findings))
            raise SystemExit
        text = str(result.get("text") or "").lower()
        expected = str(item.get("expected") or "").lower()
        hits.setdefault(bench, []).append(1.0 if expected and expected in text else 0.0)
    scores = {k: (sum(v) / len(v) if v else None) for k, v in hits.items()}
    findings.extend(score_findings(scores))
    print(json.dumps(findings))
    raise SystemExit

candidates = [p for p in (scores_path, os.path.join(os.path.dirname(scores_path or ""), "quality-scores.json")) if p]
path = next((p for p in candidates if p and os.path.isfile(p)), None)
if path is None:
    findings.append({
        "issue": "llm endpoint not provided",
        "risk": "critical",
        "tool_used": "lm-eval",
    })
    print(json.dumps(findings))
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
findings.extend(score_findings(scores))
print(json.dumps(findings))
PY
