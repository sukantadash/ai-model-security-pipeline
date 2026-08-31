#!/usr/bin/env bash
# Subtask basic-inference: ping the eval-zone LLMInferenceService (or unit fixture with no weights).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_PATH="${1:?model path required}"
OUT="${2:-/results/dynamic-basic-inference.json}"
export SCRIPT_DIR
python3 - "${MODEL_PATH}" <<'PY' | python3 "${SCRIPT_DIR}/emit_findings.py" --subtask basic-inference --tool vllm --out "${OUT}"
import json, os, sys
sys.path.insert(0, os.environ.get("SCRIPT_DIR", "/scripts"))
import vllm_client
model = sys.argv[1]
endpoint = (os.environ.get("MODEL_ENDPOINT") or "").strip()
findings = []

if endpoint:
    health = vllm_client.health(endpoint)
    models = vllm_client.models(endpoint)
    if not health.get("ok") and not models.get("ok"):
        findings.append({
            "issue": f"llm endpoint unreachable: {health.get('error') or models.get('error') or endpoint}",
            "risk": "critical",
            "tool_used": "vllm",
        })
        print(json.dumps(findings))
        raise SystemExit
    ping = vllm_client.chat(endpoint, "ping", max_tokens=8, timeout=120)
    if not ping.get("ok"):
        findings.append({
            "issue": f"vLLM chat/completions failed: {ping.get('error')}",
            "risk": "critical",
            "tool_used": "vllm",
        })
    elif not str(ping.get("text") or "").strip():
        findings.append({
            "issue": "vLLM generate() returned an empty completion",
            "risk": "high",
            "tool_used": "vllm",
        })
    print(json.dumps(findings))
    raise SystemExit

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

findings.append({
    "issue": "llm endpoint not provided",
    "risk": "critical",
    "tool_used": "vllm",
})
print(json.dumps(findings))
PY
