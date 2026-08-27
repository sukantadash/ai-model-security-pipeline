#!/usr/bin/env bash
# Shared MinIO/S3 helpers for Tekton tasks and Jobs.
configure_s3() {
  export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
  export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
  export AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}"
  ENDPOINT="${MINIO_ENDPOINT:-http://minio.minio-system.svc:9000}"
  mc alias set pipeline "${ENDPOINT}" "${AWS_ACCESS_KEY_ID}" "${AWS_SECRET_ACCESS_KEY}" >/dev/null
}

# Last five characters of the PipelineRun name (e.g. model-security-9x57m -> 9x57m).
model_version_from_run() {
  local name="${1:?pipelinerun name}"
  if (( ${#name} < 5 )); then
    echo "${name}"
  else
    echo "${name: -5}"
  fi
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
  mc mirror --overwrite "${src}/" "pipeline/models-verified/${model_id}/${version}/" >&2
  echo "s3://models-verified/${model_id}/${version}/"
}

s3_scan_result_uri() {
  local model_id="${1:?model_id}"
  local version="${2:?version}"
  echo "s3://models-eval/${model_id}/${version}/scan-result/"
}

s3_put_scan_result() {
  local model_id="${1:?model_id}"
  local version="${2:?version}"
  local src_file="${3:?src_file}"
  configure_s3
  if [[ ! -f "${src_file}" ]]; then
    echo "scan result file missing: ${src_file}" >&2
    return 1
  fi
  local name
  name="$(basename "${src_file}")"
  mc cp "${src_file}" "pipeline/models-eval/${model_id}/${version}/scan-result/${name}" >&2
  echo "s3://models-eval/${model_id}/${version}/scan-result/${name}"
}

s3_fetch_scan_prefix() {
  local model_id="${1:?model_id}"
  local version="${2:?version}"
  local dest="${3:?dest}"
  configure_s3
  mkdir -p "${dest}"
  mc mirror --overwrite "pipeline/models-eval/${model_id}/${version}/scan-result/" "${dest}/" >&2 || true
  echo "s3://models-eval/${model_id}/${version}/scan-result/"
}

s3_archive_scan_results() {
  local model_id="${1:?model_id}"
  local version="${2:?version}"
  local src="${3:?src}"
  configure_s3
  if [[ ! -d "${src}" ]]; then
    echo "scan results dir missing: ${src}" >&2
    return 1
  fi
  mc mirror --overwrite "${src}/" "pipeline/models-eval/${model_id}/${version}/scan-result/" >&2
  echo "s3://models-eval/${model_id}/${version}/scan-result/"
}

s3_upload_attestation() {
  local version="${1:?version}"
  local src_file="${2:?src_file}"
  configure_s3
  mc cp "${src_file}" "pipeline/attestations/${version}/$(basename "${src_file}")"
}
