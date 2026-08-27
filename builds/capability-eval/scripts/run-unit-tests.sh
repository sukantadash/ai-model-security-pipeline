#!/usr/bin/env bash
# Run the four capability-eval subtask scripts against testdata and validate JSON.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="${ROOT}/scripts"
DATA="${ROOT}/testdata"
OUT="${1:-${ROOT}/.unit-out}"
rm -rf "${OUT}"
mkdir -p "${OUT}"

"${SCRIPTS}/run-quality.sh" "${OUT}/capability-quality.json" "${DATA}/quality/quality-scores.json"
"${SCRIPTS}/run-performance-cost.sh" "${OUT}/capability-performance-cost.json" "${DATA}/performance-cost/perf-metrics.json"
"${SCRIPTS}/run-stability-check.sh" "${OUT}/capability-stability.json" "${DATA}/stability-check/latency-samples.json"
"${SCRIPTS}/run-anomaly-bias.sh" "${OUT}/capability-anomaly-bias.json" "${DATA}/anomaly-bias/baseline-delta.json"

python3 "${SCRIPTS}/merge-capability-eval.py" "${OUT}" "${OUT}/capability.json"
python3 "${SCRIPTS}/validate-unit-results.py" "${OUT}"
ls -l "${OUT}"
