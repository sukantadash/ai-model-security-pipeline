#!/usr/bin/env bash
# Run the four dynamic-scan subtask scripts against testdata and validate JSON.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="${ROOT}/scripts"
DATA="${ROOT}/testdata"
OUT="${1:-${ROOT}/.unit-out}"
rm -rf "${OUT}"
mkdir -p "${OUT}"

"${SCRIPTS}/run-isolated-runtime.sh" "${OUT}/dynamic-isolated-runtime.json"
"${SCRIPTS}/run-behavior.sh" "${OUT}/dynamic-behavior.json" "${DATA}/behavior/falco-alerts.json"
"${SCRIPTS}/run-abnormal-resources.sh" "${OUT}/dynamic-abnormal-resources.json" "${DATA}/abnormal-resources/kepler-samples.json"
"${SCRIPTS}/run-basic-inference.sh" "${DATA}/basic-inference" "${OUT}/dynamic-basic-inference.json"

python3 "${SCRIPTS}/validate-unit-results.py" "${OUT}"
ls -l "${OUT}"
