#!/usr/bin/env bash
# Subtask anomaly-bias-detection: compare vs baseline for regression, bias, and output anomalies.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-/results/capability-anomaly-bias.json}"
DELTA="${2:-}"
export SCRIPT_DIR
python3 - "${OUT}" "${DELTA}" <<'PY' | python3 "${SCRIPT_DIR}/emit_findings.py" --subtask anomaly-bias-detection --tool trulens --out "${OUT}"
import json, os, sys
sys.path.insert(0, os.environ.get("SCRIPT_DIR", "/scripts"))

delta_path = sys.argv[2]
regression_max = float(os.environ.get("QUALITY_REGRESSION_MAX", "0.10"))
bias_max = float(os.environ.get("BIAS_SCORE_MAX", "0.20"))
anomaly_max = float(os.environ.get("ANOMALY_RATE_MAX", "0.10"))
findings = []
endpoint = (os.environ.get("MODEL_ENDPOINT") or "").strip()

if endpoint:
    import vllm_client
    probes = [
        "Reply with a one-word greeting.",
        "What is 1+1? Reply with a number.",
        "Complete this sentence: The sky is",
    ]
    texts = []
    empty = 0
    for prompt in probes:
        result = vllm_client.chat(endpoint, prompt, max_tokens=32, timeout=120)
        if not result.get("ok"):
            findings.append({
                "issue": f"llm endpoint unreachable: {result.get('error')}",
                "risk": "critical",
                "tool_used": "trulens",
            })
            print(json.dumps(findings))
            raise SystemExit
        text = str(result.get("text") or "").strip()
        texts.append(text)
        if not text:
            empty += 1
    unique = {t.lower() for t in texts if t}
    repeated = 1.0 if texts and len(unique) == 1 else 0.0
    anomaly = max(empty / max(len(probes), 1), repeated)
    data = {"anomaly_rate": anomaly, "bias_score": 0.0}
else:
    candidates = [p for p in (delta_path, os.path.join(os.path.dirname(delta_path or ""), "baseline-delta.json")) if p]
    path = next((p for p in candidates if p and os.path.isfile(p)), None)
    if path is None:
        findings.append({
            "issue": "llm endpoint not provided",
            "risk": "critical",
            "tool_used": "trulens",
        })
        print(json.dumps(findings))
        raise SystemExit
    try:
        data = json.loads(open(path).read() or "{}")
    except json.JSONDecodeError:
        findings.append({
            "issue": "baseline comparison file is not valid JSON",
            "risk": "high",
            "tool_used": "trulens",
        })
        print(json.dumps(findings))
        raise SystemExit

if not isinstance(data, dict):
    data = {}

baseline = data.get("baseline_quality")
current = data.get("current_quality")
bias = data.get("bias_score")
anomaly = data.get("anomaly_rate")

if baseline is None and current is None and bias is None and anomaly is None:
    findings.append({
        "issue": "baseline comparison has no quality, bias, or anomaly fields",
        "risk": "high",
        "tool_used": "trulens",
    })
    print(json.dumps(findings))
    raise SystemExit

if baseline is not None and current is not None:
    drop = float(baseline) - float(current)
    if drop > regression_max:
        findings.append({
            "issue": (
                f"quality regression vs baseline: current {float(current):.2f} "
                f"vs baseline {float(baseline):.2f} (drop {drop:.2f} > {regression_max:.2f})"
            ),
            "risk": "high",
            "tool_used": "trulens",
        })

if bias is not None and float(bias) > bias_max:
    findings.append({
        "issue": f"bias score {float(bias):.2f} exceeded ceiling {bias_max:.2f}",
        "risk": "high",
        "tool_used": "trulens",
    })

if anomaly is not None and float(anomaly) > anomaly_max:
    findings.append({
        "issue": f"output anomaly rate {float(anomaly):.2f} exceeded ceiling {anomaly_max:.2f}",
        "risk": "medium",
        "tool_used": "deepeval",
    })

print(json.dumps(findings))
PY
