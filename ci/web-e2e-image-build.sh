#!/usr/bin/env bash
# Build and push the Playwright web-E2E runner image (ci/web-e2e/Dockerfile)
# so ci/web-e2e-k8s.sh can run the vendored web test suites as a Kubernetes
# Job. Mirrors ci/backend-test-image-build.sh: rootless BuildKit, Harbor
# registry cache, and only the resolved image ref on stdout.
set -euo pipefail

readonly root="$(git rev-parse --show-toplevel)"
readonly revision="$(git -C "${root}" rev-parse --short=8 HEAD)"
readonly registry="${HARBOR_REGISTRY:?HARBOR_REGISTRY is required}"
readonly project="${HARBOR_PROJECT:-artifact-keeper-ci}"
readonly cache_project="${HARBOR_CACHE_PROJECT:-artifact-keeper-cache}"
readonly image="${registry}/${project}/artifact-keeper-web-e2e-runner"
readonly tag="${revision}"
readonly cache_ref="${registry}/${cache_project}/artifact-keeper-web-e2e-runner:buildcache"

[[ -n "${HARBOR_USERNAME:-}" ]] || { echo "HARBOR_USERNAME is required" >&2; exit 2; }
[[ -n "${HARBOR_PASSWORD:-}" ]] || { echo "HARBOR_PASSWORD is required" >&2; exit 2; }

# The Playwright base image version must match the vendored @playwright/test,
# or the browsers baked into the base are rejected at runtime.
pw_version="$(jq -r '.packages["node_modules/@playwright/test"].version' \
  "${root}/artifact-keeper-web/package-lock.json")"
[[ -n "${pw_version}" && "${pw_version}" != "null" ]] || {
  echo "could not resolve @playwright/test version from the vendored lockfile" >&2
  exit 2
}

logout() { docker logout "${registry}" >/dev/null 2>&1 || true; }
trap logout EXIT

printf '%s' "${HARBOR_PASSWORD}" |
  docker login "${registry}" --username "${HARBOR_USERNAME}" --password-stdin >&2

echo "==> building ${image}:${tag} (playwright ${pw_version})" >&2
docker buildx build \
  --progress plain \
  --file "${root}/ci/web-e2e/Dockerfile" \
  --build-arg "PLAYWRIGHT_VERSION=${pw_version}" \
  --cache-from "type=registry,ref=${cache_ref}" \
  --cache-to "type=registry,ref=${cache_ref},mode=max" \
  --tag "${image}:${tag}" \
  --push \
  "${root}" >&2

# Only the resolved image ref goes to stdout; everything else above is
# routed to stderr so callers can safely capture `image=$(this script)`.
echo "${image}:${tag}"
