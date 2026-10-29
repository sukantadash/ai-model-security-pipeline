#!/usr/bin/env bash
# Retag ModelCar ${MODEL_ID}-unverified → ${MODEL_ID}-verified-SCORE-VERSION and register.
# Version is the last five characters of the PipelineRun name (e.g. 9x57m).
# score.json is read from s3://models-eval/<model-id>/<version>/scan-result/.
set -euo pipefail

MODEL_ID="${MODEL_ID:?MODEL_ID required}"
MODELCAR_IMAGE="${MODELCAR_IMAGE:?MODELCAR_IMAGE required (repo without tag)}"
MR_NS="${MODEL_REGISTRY_NAMESPACE:-rhoai-model-registries}"
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

SCORE_RAW="$(jq -r '.score // .S_total // 0' "${SCORE_FILE}")"
SCORE_TAG="$(python3 -c "print(int(round(float('${SCORE_RAW}'))))")"
SRC_IMG="${MODELCAR_IMAGE}:${MODEL_ID}-unverified"
DST_IMG="${MODELCAR_IMAGE}:${MODEL_ID}-verified-${SCORE_TAG}-${VERSION}"
if [[ -f /run/secrets/quay/.dockerconfigjson ]]; then
  export REGISTRY_AUTH_FILE=/tmp/auth.json
  cp /run/secrets/quay/.dockerconfigjson "${REGISTRY_AUTH_FILE}"
fi
skopeo copy --quiet "docker://${SRC_IMG}" "docker://${DST_IMG}"
PUBLISHED_URI="oci://${DST_IMG}"
echo "Published ModelCar ${PUBLISHED_URI} (routing=${ROUTING} score=${SCORE_TAG})"

export MR_URL PUBLISHED_URI SCAN_URI VERSION ROUTING MODEL_ID
export S3_URI="${PUBLISHED_URI}"
python3 /scripts/register_model.py

python3 - <<PY
import json
payload = {
  "status": "${ROUTING}",
  "routing": "${ROUTING}",
  "published_uri": "${PUBLISHED_URI}",
  "scan_uri": "${SCAN_URI}",
  "model_registry_namespace": "${MR_NS}",
  "model_version": "${VERSION}",
  "modelcar_image": "${DST_IMG}",
  "score": ${SCORE_TAG},
}
with open("${DEST}/publish.json", "w") as fh:
    json.dump(payload, fh, indent=2)
print(json.dumps(payload))
PY

s3_put_scan_result "${MODEL_ID}" "${VERSION}" "${DEST}/publish.json"

echo -n "${PUBLISHED_URI}"
