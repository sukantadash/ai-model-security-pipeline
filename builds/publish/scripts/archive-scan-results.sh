#!/usr/bin/env bash
# Write manifest.json into s3://models-eval/<model-id>/<version>/scan-result/.
# Subtasks already upload their JSON to that prefix.
# Version is the last five characters of the PipelineRun name.
set -euo pipefail

MODEL_ID="${MODEL_ID:?MODEL_ID required}"
PIPELINE_RUN_NAME="${PIPELINE_RUN_NAME:?PIPELINE_RUN_NAME required}"

source /scripts/s3-common.sh

VERSION="$(model_version_from_run "${PIPELINE_RUN_NAME}")"
if [[ -z "${VERSION}" ]]; then
  echo "Could not derive version from PipelineRun name '${PIPELINE_RUN_NAME}'" >&2
  exit 1
fi

DEST="${RESULTS_DIR:-/tmp/scan-result}"
s3_fetch_scan_prefix "${MODEL_ID}" "${VERSION}" "${DEST}" >/dev/null
URI=$(s3_scan_result_uri "${MODEL_ID}" "${VERSION}")

python3 - <<PY
import json
from pathlib import Path
dest = Path("${DEST}")
score_path = dest / "score.json"
payload = {
    "model_id": "${MODEL_ID}",
    "version": "${VERSION}",
    "scan_uri": "${URI}",
}
if score_path.is_file():
    summary = json.loads(score_path.read_text())
    payload["routing"] = summary.get("routing")
    payload["score"] = summary.get("S_total", summary.get("score"))
(dest / "manifest.json").write_text(json.dumps(payload, indent=2) + "\n")
print(json.dumps(payload))
PY

s3_put_scan_result "${MODEL_ID}" "${VERSION}" "${DEST}/manifest.json"
echo "Scan pack ${URI}"
echo -n "${URI}"
