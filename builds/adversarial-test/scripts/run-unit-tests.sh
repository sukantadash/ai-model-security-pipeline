#!/usr/bin/env bash
# Run the three adversarial-test subtask scripts against testdata and validate JSON.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="${ROOT}/scripts"
DATA="${ROOT}/testdata"
OUT="${1:-${ROOT}/.unit-out}"
rm -rf "${OUT}"
mkdir -p "${OUT}"

"${SCRIPTS}/run-prompt-injection.sh" \
  "${OUT}/adversarial-prompt-injection.json" \
  "${DATA}/prompt-injection/injection-probes.json"
"${SCRIPTS}/run-jailbreak-guardrail-bypass.sh" \
  "${OUT}/adversarial-jailbreak-guardrail-bypass.json" \
  "${DATA}/jailbreak-guardrail-bypass/jailbreak-probes.json"
"${SCRIPTS}/run-harmful-content-bias.sh" \
  "${OUT}/adversarial-harmful-content-bias.json" \
  "${DATA}/harmful-content-bias/harmful-bias-probes.json"

python3 "${SCRIPTS}/merge-adversarial-test.py" "${OUT}" "${OUT}/adversarial-test.json"
python3 "${SCRIPTS}/validate-unit-results.py" "${OUT}"
ls -l "${OUT}"
