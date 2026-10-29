#!/usr/bin/env bash
# Clone git-url and replace placeholder image URI in one LLMInferenceService YAML file.
# Optional: TEST_SERVING_OUT — copy overlays/16-test-serving + instances/model-test so
# publish-artifact can oc apply -k that overlay before the verified LLMIS.
set -euo pipefail
GIT_URL="${GIT_URL:?GIT_URL required}"
GIT_PATH="${GIT_PATH:?GIT_PATH required (file path inside the repo)}"
OUT_DIR="${OUT_DIR:?OUT_DIR required}"
MODEL_URI="${MODEL_URI:?MODEL_URI required}"
NAMESPACE="${NAMESPACE:-}"
GIT_REVISION="${GIT_REVISION:-}"
TEST_SERVING_OUT="${TEST_SERVING_OUT:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CLONE="$(mktemp -d)"
trap 'rm -rf "${CLONE}"' EXIT

git_args=(clone --depth 1)
if [[ -n "${GIT_REVISION}" ]]; then
  git_args+=(--branch "${GIT_REVISION}")
fi
if [[ -n "${GIT_TOKEN:-}" ]]; then
  case "${GIT_URL}" in
    https://*)
      GIT_URL="${GIT_URL/https:\/\//https://x-access-token:${GIT_TOKEN}@}"
      ;;
  esac
fi
git "${git_args[@]}" "${GIT_URL}" "${CLONE}"

SRC="${CLONE}/${GIT_PATH}"
if [[ ! -f "${SRC}" ]]; then
  echo "serving YAML file not found: ${GIT_PATH} in ${GIT_URL}" >&2
  ls -la "$(dirname "${SRC}")" >&2 || true
  exit 1
fi

python3 "${SCRIPT_DIR}/patch_llmis.py" "${SRC}" \
  --out-dir "${OUT_DIR}" \
  --model-uri "${MODEL_URI}" \
  ${NAMESPACE:+--namespace "${NAMESPACE}"}

NAME="$(python3 "${SCRIPT_DIR}/patch_llmis.py" "${SRC}" --print-name)"
echo -n "${NAME}" > "${OUT_DIR}/.llmis-name"
echo "service name ${NAME}"

if [[ -n "${TEST_SERVING_OUT}" ]]; then
  OVERLAY_SRC="${CLONE}/overlays/16-test-serving"
  INST_SRC="${CLONE}/instances/model-test"
  if [[ ! -d "${OVERLAY_SRC}" ]] || [[ ! -d "${INST_SRC}" ]]; then
    echo "test-serving overlay missing in clone (need overlays/16-test-serving and instances/model-test)" >&2
    exit 1
  fi
  rm -rf "${TEST_SERVING_OUT}"
  mkdir -p "${TEST_SERVING_OUT}/overlays" "${TEST_SERVING_OUT}/instances"
  cp -a "${OVERLAY_SRC}" "${TEST_SERVING_OUT}/overlays/16-test-serving"
  cp -a "${INST_SRC}" "${TEST_SERVING_OUT}/instances/model-test"
  echo "staged ${TEST_SERVING_OUT}/overlays/16-test-serving for apply"
fi
