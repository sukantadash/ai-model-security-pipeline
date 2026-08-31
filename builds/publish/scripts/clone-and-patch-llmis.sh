#!/usr/bin/env bash
# Clone git-url and patch LLMInferenceService YAML under a repo path.
set -euo pipefail
GIT_URL="${GIT_URL:?GIT_URL required}"
GIT_PATH="${GIT_PATH:?GIT_PATH required (path inside the repo)}"
OUT_DIR="${OUT_DIR:?OUT_DIR required}"
NAME="${NAME:-}"
MODEL_NAME="${MODEL_NAME:-}"
MODEL_URI="${MODEL_URI:?MODEL_URI required}"
MODEL_VERSION="${MODEL_VERSION:-}"
NAMESPACE="${NAMESPACE:-}"
GIT_REVISION="${GIT_REVISION:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CLONE="$(mktemp -d)"
trap 'rm -rf "${CLONE}"' EXIT

git_args=(clone --depth 1)
if [[ -n "${GIT_REVISION}" ]]; then
  git_args+=(--branch "${GIT_REVISION}")
fi
if [[ -n "${GIT_TOKEN:-}" ]]; then
  # https://github.com/org/repo.git → https://x-access-token:TOKEN@github.com/org/repo.git
  case "${GIT_URL}" in
    https://*)
      GIT_URL="${GIT_URL/https:\/\//https://x-access-token:${GIT_TOKEN}@}"
      ;;
  esac
fi
git "${git_args[@]}" "${GIT_URL}" "${CLONE}"

SRC="${CLONE}/${GIT_PATH}"
if [[ ! -e "${SRC}" ]]; then
  echo "git path not found: ${GIT_PATH} in ${GIT_URL}" >&2
  ls -la "${CLONE}" >&2 || true
  exit 1
fi

python3 "${SCRIPT_DIR}/patch_llmis.py" "${SRC}" \
  --out-dir "${OUT_DIR}" \
  --model-uri "${MODEL_URI}" \
  ${NAME:+--name "${NAME}"} \
  ${MODEL_NAME:+--model-name "${MODEL_NAME}"} \
  ${MODEL_VERSION:+--model-version "${MODEL_VERSION}"} \
  ${REGISTERED_MODEL:+--registered-model "${REGISTERED_MODEL}"} \
  ${NAMESPACE:+--namespace "${NAMESPACE}"}
