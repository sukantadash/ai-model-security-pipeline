#!/usr/bin/env bash
# Subtask basic-inference: vLLM load + short generate inside the Kata VM.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_PATH="${1:?model path required}"
OUT="${2:-/results/dynamic-basic-inference.json}"
python3 - "${MODEL_PATH}" <<'PY' | python3 "${SCRIPT_DIR}/emit_findings.py" --subtask basic-inference --tool vllm --out "${OUT}"
import json, os, sys

model = sys.argv[1]
findings = []
if not os.path.isdir(model):
    findings.append({
        "issue": f"model path missing: {model}",
        "risk": "critical",
        "tool_used": "vllm",
    })
    print(json.dumps(findings))
    raise SystemExit

weights = []
for root, _, files in os.walk(model):
    for name in files:
        if name.endswith((".safetensors", ".bin", ".pt", ".gguf")):
            weights.append(os.path.join(root, name))

if not weights:
    findings.append({
        "issue": "no loadable weight files for inference probe",
        "risk": "critical",
        "tool_used": "vllm",
    })
    print(json.dumps(findings))
    raise SystemExit

try:
    from fickling.hook import activate_safe_ml_environment

    activate_safe_ml_environment()
except Exception as exc:
    findings.append({
        "issue": f"Fickling allowlist not applied: {exc}",
        "risk": "medium",
        "tool_used": "fickling",
    })

try:
    import vllm  # noqa: F401
except ImportError:
    findings.append({
        "issue": "vLLM is not installed in the dynamic-scan image; basic inference did not run",
        "risk": "high",
        "tool_used": "vllm",
    })
    print(json.dumps(findings))
    raise SystemExit

try:
    from vllm import LLM, SamplingParams
    llm = LLM(model=model, max_model_len=int(os.environ.get("MAX_MODEL_LEN", "512")))
    out = llm.generate(["ping"], SamplingParams(max_tokens=8, temperature=0.0))
    text = ""
    if out and out[0].outputs:
        text = out[0].outputs[0].text or ""
    if not text.strip():
        findings.append({
            "issue": "vLLM generate() returned an empty completion",
            "risk": "high",
            "tool_used": "vllm",
        })
except Exception as exc:
    findings.append({
        "issue": f"vLLM load/generate failed: {exc}",
        "risk": "critical",
        "tool_used": "vllm",
    })
print(json.dumps(findings))
PY
