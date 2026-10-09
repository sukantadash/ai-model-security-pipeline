#!/usr/bin/env bash
# Build and push ModelCar image.
# Image: ${MODELCAR_IMAGE}:${MODEL_ID}-unverified
#   e.g. quay.io/sudash/ai-model-security-pipeline:redhatai-qwen3-8b-fp8-dynamic-unverified
set -euo pipefail

HF_REPO="${HF_REPO:?HF_REPO required}"
MODEL_ID="${MODEL_ID:?MODEL_ID required}"
MODELCAR_IMAGE="${MODELCAR_IMAGE:?MODELCAR_IMAGE required (repo without tag)}"
CONTEXT_DIR="${CONTEXT_DIR:-/build}"
TAG="${MODELCAR_TAG:-${MODEL_ID}-unverified}"
FULL_IMAGE="${MODELCAR_IMAGE}:${TAG}"

export STORAGE_DRIVER="${STORAGE_DRIVER:-vfs}"
export BUILDAH_ISOLATION="${BUILDAH_ISOLATION:-chroot}"

echo "Building ModelCar ${FULL_IMAGE} from HF_REPO=${HF_REPO} MODEL_ID=${MODEL_ID}"

AUTHFILE="${REGISTRY_AUTH_FILE:-/tmp/auth.json}"
if [[ -f /var/run/secrets/kubernetes.io/dockerconfigjson/.dockerconfigjson ]]; then
  cp /var/run/secrets/kubernetes.io/dockerconfigjson/.dockerconfigjson "${AUTHFILE}"
elif [[ -f /run/secrets/quay/.dockerconfigjson ]]; then
  cp /run/secrets/quay/.dockerconfigjson "${AUTHFILE}"
fi
if [[ ! -s "${AUTHFILE}" ]]; then
  echo "Quay authfile missing or empty at ${AUTHFILE}; mount sudash-modelpipeline-pull-secret" >&2
  exit 1
fi
export REGISTRY_AUTH_FILE="${AUTHFILE}"
mkdir -p "${HOME:-/tmp}/.docker"
cp "${AUTHFILE}" "${HOME:-/tmp}/.docker/config.json"

build_args=(
  bud
  --storage-driver "${STORAGE_DRIVER}"
  --isolation "${BUILDAH_ISOLATION}"
  -f "${CONTEXT_DIR}/Containerfile"
  -t "${FULL_IMAGE}"
  --build-arg "HF_REPO=${HF_REPO}"
)
if [[ -n "${HF_TOKEN:-}" ]]; then
  build_args+=(--build-arg "HF_TOKEN=${HF_TOKEN}")
fi
# Optional extra download patterns (comma-separated, e.g. "*.jinja" for models whose
# chat template is a separate chat_template.jinja). Unset = default patterns only.
if [[ -n "${HF_EXTRA_PATTERNS:-}" ]]; then
  build_args+=(--build-arg "HF_EXTRA_PATTERNS=${HF_EXTRA_PATTERNS}")
  echo "Extra download patterns: ${HF_EXTRA_PATTERNS}"
fi
build_args+=("${CONTEXT_DIR}")

buildah "${build_args[@]}"
buildah push \
  --authfile "${AUTHFILE}" \
  --storage-driver "${STORAGE_DRIVER}" \
  "${FULL_IMAGE}" \
  "docker://${FULL_IMAGE}"

echo "Pushed ${FULL_IMAGE}"
