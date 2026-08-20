#!/usr/bin/env bash
set -euo pipefail
MODEL_PATH="${1:?model path required}"
OUT="${2:-/results/dynamic-probe.json}"
mkdir -p "$(dirname "$OUT")"

STATUS="pass"
DETAIL="metadata and layout probe passed"

if [[ ! -d "${MODEL_PATH}" ]]; then
  STATUS="fail"
  DETAIL="model path missing"
fi

# Lightweight probe only — runs under Kata (no GPU).
WEIGHT_COUNT=$(find "${MODEL_PATH}" -type f \( -name '*.safetensors' -o -name '*.bin' -o -name '*.pt' \) 2>/dev/null | wc -l | tr -d ' ')
if [[ "${WEIGHT_COUNT}" -eq 0 ]]; then
  STATUS="fail"
  DETAIL="no weight files found"
fi

python3 - <<PY
import json
print(json.dumps({
  "status": "${STATUS}",
  "scanner": "dynamic-probe",
  "model": "${MODEL_PATH}",
  "weight_files": int("${WEIGHT_COUNT}"),
  "detail": """${DETAIL}""",
  "runtime": "kata"
}, indent=2))
PY > "${OUT}"
cat "${OUT}"
[[ "${STATUS}" == "pass" ]]
