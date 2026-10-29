#!/usr/bin/env bash
set -euo pipefail
# Usage: download-hf-model.sh <repo_id> <local_dir> [model_id]
# Weights for the pipeline are packaged as ModelCar by instances/model-ingress-fetch
# (build-modelcar.sh). This helper remains for local/debug downloads only.
REPO_ID="${1:?repo_id required}"
LOCAL_DIR="${2:?local_dir required}"
MODEL_ID="${3:-$(echo "${REPO_ID}" | tr '/:' '-' | tr '[:upper:]' '[:lower:]')}"

python -c "from huggingface_hub import snapshot_download; snapshot_download('${REPO_ID}', local_dir='${LOCAL_DIR}')"
echo "Downloaded ${REPO_ID} (${MODEL_ID}) to ${LOCAL_DIR}"
