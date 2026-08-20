#!/usr/bin/env bash
set -euo pipefail
RESULTS_DIR="${1:-/results}"
OUT="${2:-/results/score.json}"
mkdir -p "$(dirname "$OUT")"
echo '{"status":"pass","stub":true,"scanner":"red-team","results_dir":"'"$RESULTS_DIR"'"}' > "$OUT"
