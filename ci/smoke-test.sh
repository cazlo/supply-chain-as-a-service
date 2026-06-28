#!/usr/bin/env bash
set -euo pipefail

# Run the vendored artifact-keeper smoke suite (pypi, npm, cargo native clients)
# against a freshly built backend, without modifying the imported test tree.
#
# The upstream scripts/run-e2e-tests.sh smoke path also drives a Playwright
# service that is not present in docker-compose.test.yml, so this wrapper invokes
# the compose project directly. Docker Compose resolves the compose file's
# relative build context and bind mounts against its own directory, so pointing
# at the absolute compose path keeps the vendored sources untouched.

readonly root="$(git rev-parse --show-toplevel)"
readonly compose_file="${root}/artifact-keeper/docker-compose.test.yml"

compose() {
  docker compose --file "${compose_file}" --profile smoke "$@"
}

teardown() {
  compose down --volumes --remove-orphans >/dev/null 2>&1 || true
}

main() {
  local tests=("$@")
  [[ ${#tests[@]} -gt 0 ]] || tests=(pypi-test npm-test cargo-test)

  trap teardown EXIT
  teardown # discard any stale project state from an earlier run

  # Build the pinned backend image and wait for the infrastructure and
  # repository bootstrap to report healthy before any client test runs.
  compose up --detach --build --wait postgres backend trivy pki setup

  local status=0 test
  for test in "${tests[@]}"; do
    if compose run --no-deps --rm "${test}"; then
      echo "PASS ${test}"
    else
      echo "FAIL ${test}"
      status=1
    fi
  done

  return "${status}"
}

main "$@"
