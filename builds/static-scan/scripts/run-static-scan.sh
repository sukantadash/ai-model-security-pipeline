#!/usr/bin/env bash
set -euo pipefail
MODEL_PATH="${1:?model path required}"
OUT="${2:?output json required}"
SUBTASK="${3:?subtask required}"
mkdir -p "$(dirname "$OUT")"
export HF_HUB_OFFLINE="${HF_HUB_OFFLINE:-1}"
export TRANSFORMERS_OFFLINE="${TRANSFORMERS_OFFLINE:-1}"
export PROMPTFOO_DISABLE_SHARING="${PROMPTFOO_DISABLE_SHARING:-true}"
export GRYPE_DB_AUTO_UPDATE="${GRYPE_DB_AUTO_UPDATE:-false}"
export STATIC_SCAN_POLICY="${STATIC_SCAN_POLICY:-/etc/static-scan/policy.json}"
python3 /scripts/static_scan.py "${MODEL_PATH}" "${OUT}" "${SUBTASK}"
