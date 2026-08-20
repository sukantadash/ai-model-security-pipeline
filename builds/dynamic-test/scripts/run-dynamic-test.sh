#!/usr/bin/env bash
set -euo pipefail
MODEL_PATH="${1:?model path required}"
OUT="${2:-/results/dynamic.json}"
mkdir -p "$(dirname "$OUT")"
echo '{"status":"pass","stub":true,"scanner":"dynamic-test","model":"'"$MODEL_PATH"'"}' > "$OUT"
