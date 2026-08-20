#!/usr/bin/env bash
# Promote verified model to MinIO and register in RHOAI Model Registry.
set -euo pipefail

MODEL_ID="${MODEL_ID:?MODEL_ID required}"
MODEL_PATH="${MODEL_PATH:?MODEL_PATH required}"
RESULTS_DIR="${RESULTS_DIR:?RESULTS_DIR required}"
VERSION="${MODEL_VERSION:-$(date -u +%Y%m%d%H%M%S)}"
MR_NS="${MODEL_REGISTRY_NAMESPACE:-rhoai-model-registries}"
MR_URL="${MODEL_REGISTRY_URL:-http://model-registry-service.${MR_NS}.svc:8080}"
SCORE_FILE="${SCORE_FILE:-${RESULTS_DIR}/score.json}"

source /scripts/s3-common.sh

S3_URI=$(s3_promote_verified "${MODEL_ID}" "${VERSION}" "${MODEL_PATH}")
echo "Promoted to ${S3_URI}"

if [[ -f "${SCORE_FILE}" ]]; then
  RUN_ID="${PIPELINE_RUN_ID:-manual}"
  s3_upload_attestation "${RUN_ID}" "${SCORE_FILE}" || true
fi

REGISTER_PAYLOAD=$(jq -n \
  --arg name "${MODEL_ID}" \
  --arg uri "${S3_URI}" \
  --arg version "${VERSION}" \
  '{name: $name, description: "Verified by model-security-pipeline", customProperties: {storage_uri: $uri, version: $version}}')

HTTP_CODE=$(curl -sS -o /tmp/mr-register.json -w '%{http_code}' \
  -X POST "${MR_URL}/api/model_registry/v1alpha3/registered_models" \
  -H 'Content-Type: application/json' \
  -d "${REGISTER_PAYLOAD}" || echo "000")

if [[ "${HTTP_CODE}" != "201" && "${HTTP_CODE}" != "200" ]]; then
  echo "Model Registry registration returned ${HTTP_CODE}; body:" >&2
  cat /tmp/mr-register.json >&2 || true
  echo "Continuing — update registry manually if needed." >&2
fi

python3 - <<PY
import json
payload = {
  "status": "pass",
  "published_uri": "${S3_URI}",
  "model_registry_namespace": "${MR_NS}",
  "model_version": "${VERSION}",
}
with open("${RESULTS_DIR}/publish.json", "w") as fh:
    json.dump(payload, fh, indent=2)
print(json.dumps(payload))
PY

echo -n "${S3_URI}"
