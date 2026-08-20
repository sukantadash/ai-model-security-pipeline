#!/usr/bin/env bash
set -euo pipefail
# Usage: download-hf-model.sh <repo_id> <local_dir> [model_id_for_s3]
REPO_ID="${1:?repo_id required}"
LOCAL_DIR="${2:?local_dir required}"
MODEL_ID="${3:-$(echo "${REPO_ID}" | tr '/:' '-' | tr '[:upper:]' '[:lower:]')}"

source /scripts/s3-common.sh

python -c "from huggingface_hub import snapshot_download; snapshot_download('${REPO_ID}', local_dir='${LOCAL_DIR}')"

if [[ -n "${MINIO_ENDPOINT:-}" ]]; then
  configure_s3
  mc mirror --overwrite "${LOCAL_DIR}/" "pipeline/models-ingress/${MODEL_ID}/"
  echo "Uploaded to s3://models-ingress/${MODEL_ID}/"
fi
