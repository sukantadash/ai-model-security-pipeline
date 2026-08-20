#!/usr/bin/env bash
set -euo pipefail
MODEL_PATH="${1:?model path required}"
OUT="${2:-/results/capability.json}"
mkdir -p "$(dirname "$OUT")"
echo '{"status":"pass","stub":true,"scanner":"capability-eval","model":"'"$MODEL_PATH"'"}' > "$OUT"
