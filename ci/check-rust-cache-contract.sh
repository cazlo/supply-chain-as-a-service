#!/usr/bin/env bash
# Guard the persistent BuildKit cargo/target mounts fixed in Gitea PR #43.
set -euo pipefail

readonly root="$(git rev-parse --show-toplevel)"

if grep -REn --include='*.sh' --include='*.yml' --include='*.yaml' \
  '^[[:space:]]*--no-cache-filter([=[:space:]]|$)' \
  "${root}/ci" "${root}/.gitea/workflows"; then
  echo "PR #43 regression: --no-cache-filter resets Rust cache mounts" >&2
  exit 1
fi

grep -q 'ARG CACHE_BUST=0' "${root}/ci/local-ci/Dockerfile.runner"
grep -q -- '--build-arg "CACHE_BUST=' "${root}/ci/backend-quality-k8s.sh"
grep -q -- '--build-arg "CACHE_BUST=' "${root}/ci/backend-lint.sh"

echo "PASS Rust cache contract"
