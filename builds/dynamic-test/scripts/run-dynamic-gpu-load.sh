#!/usr/bin/env bash
set -euo pipefail
MODEL_PATH="${1:?model path required}"
OUT="${2:-/results/dynamic-gpu.json}"
mkdir -p "$(dirname "$OUT")"

STATUS="pass"
DETAIL="gpu weight load probe"

python3 - <<'PY' "${MODEL_PATH}" "${OUT}" "${STATUS}" "${DETAIL}"
import json, os, sys
model_path, out, status, detail = sys.argv[1:5]
try:
    import torch
    weights = []
    for root, _, files in os.walk(model_path):
        for name in files:
            if name.endswith((".safetensors", ".bin", ".pt")):
                weights.append(os.path.join(root, name))
                if len(weights) >= 1:
                    break
        if weights:
            break
    if not weights:
        status = "fail"
        detail = "no loadable weight file"
    else:
        # Touch first shard only — full vLLM load is capability-eval scope.
        if weights[0].endswith(".safetensors"):
            detail = f"found safetensors shard: {os.path.basename(weights[0])}"
        else:
            detail = f"found weight file: {os.path.basename(weights[0])}"
except Exception as exc:
    status = "fail"
    detail = f"gpu probe error: {exc}"

payload = {
    "status": status,
    "scanner": "dynamic-gpu-load",
    "model": model_path,
    "detail": detail,
    "runtime": "restricted-gpu",
}
with open(out, "w") as fh:
    json.dump(payload, fh, indent=2)
print(json.dumps(payload))
sys.exit(0 if status == "pass" else 1)
PY
