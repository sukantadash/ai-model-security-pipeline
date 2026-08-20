#!/usr/bin/env bash
# Shared MinIO/S3 helpers for Tekton tasks and Jobs.
configure_s3() {
  export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
  export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
  export AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}"
  ENDPOINT="${MINIO_ENDPOINT:-http://minio.minio-system.svc:9000}"
  mc alias set pipeline "${ENDPOINT}" "${AWS_ACCESS_KEY_ID}" "${AWS_SECRET_ACCESS_KEY}" >/dev/null
}

s3_sync_from_ingress() {
  local model_id="${1:?model_id}"
  local dest="${2:?dest}"
  configure_s3
  mkdir -p "${dest}"
  mc mirror --overwrite "pipeline/models-ingress/${model_id}/" "${dest}/"
}

s3_promote_verified() {
  local model_id="${1:?model_id}"
  local version="${2:?version}"
  local src="${3:?src}"
  configure_s3
  mc mirror --overwrite "${src}/" "pipeline/models-verified/${model_id}/${version}/"
  echo "s3://models-verified/${model_id}/${version}/"
}

s3_upload_attestation() {
  local run_id="${1:?run_id}"
  local src_file="${2:?src_file}"
  configure_s3
  mc cp "${src_file}" "pipeline/attestations/${run_id}/$(basename "${src_file}")"
}
