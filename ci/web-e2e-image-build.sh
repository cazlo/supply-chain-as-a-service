#!/usr/bin/env bash
# Build and push the Playwright web-E2E runner image (ci/web-e2e/Dockerfile)
# so ci/web-e2e-run-compose.sh can run the vendored web test suites without
# compiling or building on Podman. Mirrors ci/backend-test-image-build.sh:
# rootless BuildKit, Harbor registry cache, and only the immutable image ref
# on stdout.
set -euo pipefail

readonly root="$(git rev-parse --show-toplevel)"
readonly revision="$(git -C "${root}" rev-parse --short=8 HEAD)"
readonly registry="${HARBOR_REGISTRY:?HARBOR_REGISTRY is required}"
readonly project="${HARBOR_PROJECT:-artifact-keeper-ci}"
readonly cache_project="${HARBOR_CACHE_PROJECT:-artifact-keeper-cache}"
readonly image="${registry}/${project}/artifact-keeper-web-e2e-runner"
readonly tag="${revision}"
readonly cache_ref="${registry}/${cache_project}/artifact-keeper-web-e2e-runner:buildcache"
readonly metadata_file="${TMPDIR:-/tmp}/ak-web-e2e-${revision}-${GITEA_RUN_ID:-$$}.json"

[[ -n "${HARBOR_USERNAME:-}" ]] || { echo "HARBOR_USERNAME is required" >&2; exit 2; }
[[ -n "${HARBOR_PASSWORD:-}" ]] || { echo "HARBOR_PASSWORD is required" >&2; exit 2; }

# The Playwright base image version must match the vendored @playwright/test,
# or the browsers baked into the base are rejected at runtime. The base is
# pinned by digest (runner-image policy); when a vendor update bumps
# @playwright/test, re-pin deliberately:
#   curl -sI "https://mcr.microsoft.com/v2/playwright/manifests/v<ver>-noble" \
#     -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
#     | grep -i etag
readonly pinned_pw_version="1.58.2"
readonly pinned_pw_digest="sha256:6446946a1d9fd62d9ae501312a2d76a43ee688542b21622056a372959b65d63d"
pw_version="$(jq -r '.packages["node_modules/@playwright/test"].version' \
  "${root}/artifact-keeper-web/package-lock.json")"
if [[ "${pw_version}" != "${pinned_pw_version}" ]]; then
  echo "vendored @playwright/test is ${pw_version} but the base image is pinned at ${pinned_pw_version}; re-pin pinned_pw_version/pinned_pw_digest in $0" >&2
  exit 2
fi
readonly base_image="mcr.microsoft.com/playwright:v${pinned_pw_version}-noble@${pinned_pw_digest}"

cleanup() {
  rm -f "${metadata_file}"
  docker logout "${registry}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

printf '%s' "${HARBOR_PASSWORD}" |
  docker login "${registry}" --username "${HARBOR_USERNAME}" --password-stdin >&2

echo "==> building ${image}:${tag} (playwright ${pw_version}, base ${pinned_pw_digest:0:19})" >&2
docker buildx build \
  --progress plain \
  --file "${root}/ci/web-e2e/Dockerfile" \
  --build-arg "PLAYWRIGHT_IMAGE=${base_image}" \
  --cache-from "type=registry,ref=${cache_ref}" \
  --cache-to "type=registry,ref=${cache_ref},mode=max" \
  --metadata-file "${metadata_file}" \
  --tag "${image}:${tag}" \
  --push \
  "${root}" >&2

digest="$(jq -er '."containerimage.digest"' "${metadata_file}")"

# The runner is an unsigned, short-lived CI artifact. Its immutable digest is
# therefore the consumer integrity boundary instead of its mutable short tag.
echo "${image}@${digest}"
