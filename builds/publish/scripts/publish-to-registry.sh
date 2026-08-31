#!/usr/bin/env bash
# Promote verified model weights to MinIO and register in RHOAI Model Registry.
# Version is the last five characters of the PipelineRun name (e.g. 9x57m).
# score.json is read from s3://models-eval/<model-id>/<version>/scan-result/.
set -euo pipefail

MODEL_ID="${MODEL_ID:?MODEL_ID required}"
MODEL_PATH="${MODEL_PATH:?MODEL_PATH required}"
MR_NS="${MODEL_REGISTRY_NAMESPACE:-rhoai-model-registries}"
# RHOAI exposes REST through kube-rbac-proxy on :8443 (the Service has no :8080).
MR_URL="${MODEL_REGISTRY_URL:-https://model-registry.${MR_NS}.svc:8443}"

source /scripts/s3-common.sh

if [[ -n "${MODEL_VERSION:-}" ]]; then
  VERSION="${MODEL_VERSION}"
elif [[ -n "${PIPELINE_RUN_NAME:-}" ]]; then
  VERSION="$(model_version_from_run "${PIPELINE_RUN_NAME}")"
else
  echo "MODEL_VERSION or PIPELINE_RUN_NAME required (last five chars of PipelineRun name)" >&2
  exit 1
fi

DEST="${RESULTS_DIR:-/tmp/scan-result}"
s3_fetch_scan_prefix "${MODEL_ID}" "${VERSION}" "${DEST}" >/dev/null
SCAN_URI=$(s3_scan_result_uri "${MODEL_ID}" "${VERSION}")
SCORE_FILE="${SCORE_FILE:-${DEST}/score.json}"

if [[ ! -f "${SCORE_FILE}" ]]; then
  echo "score.json missing at ${SCAN_URI}; refusing promote" >&2
  exit 1
fi

PASSED="$(jq -r '.passed // false' "${SCORE_FILE}")"
ROUTING="$(jq -r '.routing // empty' "${SCORE_FILE}")"
if [[ "${ROUTING}" != "auto-pass" && "${ROUTING}" != "review" ]]; then
  echo "refusing promote: passed=${PASSED} routing=${ROUTING}" >&2
  exit 1
fi

S3_URI=$(s3_promote_verified "${MODEL_ID}" "${VERSION}" "${MODEL_PATH}")
echo "Promoted weights to ${S3_URI} (routing=${ROUTING})"

export MR_URL S3_URI SCAN_URI VERSION ROUTING MODEL_ID
python3 /scripts/register_model.py

python3 - <<PY
import json
payload = {
  "status": "${ROUTING}",
  "routing": "${ROUTING}",
  "published_uri": "${S3_URI}",
  "scan_uri": "${SCAN_URI}",
  "model_registry_namespace": "${MR_NS}",
  "model_version": "${VERSION}",
}
with open("${DEST}/publish.json", "w") as fh:
    json.dump(payload, fh, indent=2)
print(json.dumps(payload))
PY

s3_put_scan_result "${MODEL_ID}" "${VERSION}" "${DEST}/publish.json"

echo -n "${S3_URI}"
