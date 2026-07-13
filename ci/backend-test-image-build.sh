#!/usr/bin/env bash
# Compile every backend/tests/*.rs integration-test binary ONCE and push the
# result to Harbor, so backend-integration's matrix legs can each pull the
# same image and just run their one target instead of recompiling the whole
# dev-dependency graph per leg (see ci/local-ci/Dockerfile.runner's
# test-artifacts stage and ci/backend-integration-run-k8s.sh).
set -euo pipefail

readonly root="$(git rev-parse --show-toplevel)"
readonly revision="$(git -C "${root}" rev-parse --short=8 HEAD)"
readonly registry="${HARBOR_REGISTRY:?HARBOR_REGISTRY is required}"
readonly project="${HARBOR_PROJECT:-artifact-keeper-ci}"
readonly cache_project="${HARBOR_CACHE_PROJECT:-artifact-keeper-cache}"
readonly image="${registry}/${project}/artifact-keeper-backend-test-runner"
readonly tag="${revision}"
readonly cache_ref="${registry}/${cache_project}/artifact-keeper-backend-test-runner:buildcache"
readonly metadata_file="${TMPDIR:-/tmp}/ak-test-runner-${revision}-${GITEA_RUN_ID:-$$}.json"

[[ -n "${HARBOR_USERNAME:-}" ]] || { echo "HARBOR_USERNAME is required" >&2; exit 2; }
[[ -n "${HARBOR_PASSWORD:-}" ]] || { echo "HARBOR_PASSWORD is required" >&2; exit 2; }

cleanup() {
  rm -f "${metadata_file}"
  docker logout "${registry}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

printf '%s' "${HARBOR_PASSWORD}" |
  docker login "${registry}" --username "${HARBOR_USERNAME}" --password-stdin >&2

echo "==> building ${image}:${tag} (target: test-artifacts)" >&2
docker buildx build \
  --progress plain \
  --file "${root}/ci/local-ci/Dockerfile.runner" \
  --target test-artifacts \
  --cache-from "type=registry,ref=${cache_ref}" \
  --cache-to "type=registry,ref=${cache_ref},mode=max" \
  --metadata-file "${metadata_file}" \
  --tag "${image}:${tag}" \
  --push \
  "${root}" >&2

digest="$(jq -er '."containerimage.digest"' "${metadata_file}")"

# Only the immutable image ref goes to stdout; everything else above is routed
# to stderr so callers can safely capture `image=$(this script)`. The image is
# an unsigned, short-lived CI artifact, so its digest is the consumer integrity
# boundary rather than a mutable tag or a cosign signature.
echo "${image}@${digest}"
