#!/usr/bin/env bash
# Run the vendored pypi/npm/cargo native-client smoke suite against the exact
# signed backend digest produced by backend-build. No backend build occurs on
# the classic-Podman Compose runner.
set -euo pipefail

readonly root="$(git rev-parse --show-toplevel)"
readonly compose_file="${root}/artifact-keeper/docker-compose.test.yml"
readonly override_file="${root}/ci/backend-smoke-compose.override.yml"
readonly backend_image="${BACKEND_IMAGE_REF:?BACKEND_IMAGE_REF is required}"
readonly harbor_registry="${HARBOR_REGISTRY:?HARBOR_REGISTRY is required}"
readonly harbor_username="${HARBOR_USERNAME:?HARBOR_USERNAME is required}"
readonly harbor_password="${HARBOR_PASSWORD:?HARBOR_PASSWORD is required}"
readonly revision="$(git rev-parse --short=8 HEAD)"
readonly run_suffix="${GITEA_RUN_NUMBER:-${GITHUB_RUN_NUMBER:-0}}"
readonly results_dir="${SMOKE_RESULTS_DIR:-/tmp/artifact-keeper-backend-smoke-compose}"
readonly timeout_seconds="${COMPOSE_SMOKE_TIMEOUT_SECONDS:-1200}"
readonly runner_docker_config="${DOCKER_CONFIG:-${HOME}/.docker}"
readonly cleanup_timeout_seconds="${COMPOSE_CLEANUP_COMMAND_TIMEOUT_SECONDS:-30}"

run_id="${GITEA_RUN_ID:-${GITHUB_RUN_ID:-${run_suffix}}}"
run_attempt="${GITEA_RUN_ATTEMPT:-${GITHUB_RUN_ATTEMPT:-1}}"
export COMPOSE_PROJECT_NAME="ak-smoke-${revision}-${run_id}-${run_attempt}"
export SMOKE_CONTAINER_PREFIX="${COMPOSE_PROJECT_NAME}"
export SMOKE_NETWORK_NAME="${COMPOSE_PROJECT_NAME}-network"
export BACKEND_IMAGE_REF="${backend_image}"

readonly active_test_container="${COMPOSE_PROJECT_NAME}-active-test"
readonly docker_config="${TMPDIR:-/tmp}/${COMPOSE_PROJECT_NAME}-docker-config"

COMPOSE_RUNTIME_RESULTS_DIR="${results_dir}"
COMPOSE_RUNTIME_DOCKER_CONFIG="${docker_config}"
COMPOSE_RUNTIME_RUNNER_DOCKER_CONFIG="${runner_docker_config}"
COMPOSE_RUNTIME_TEST_CONTAINER="${active_test_container}"
COMPOSE_RUNTIME_NETWORK_PATTERN="^${SMOKE_NETWORK_NAME}$"
COMPOSE_RUNTIME_CLEANUP_COMMAND_TIMEOUT_SECONDS="${cleanup_timeout_seconds}"
COMPOSE_RUNTIME_COMPOSE_ARGS=(
  --file "${compose_file}"
  --file "${override_file}"
  --profile smoke
)
# shellcheck source=ci/compose-runtime-lib.sh
source "${root}/ci/compose-runtime-lib.sh"
compose_runtime_init
mkdir -p "${root}/artifact-keeper/.pki"

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  compose_runtime_finalize "${rc}"
  exit $?
}
trap cleanup EXIT

trap 'compose_runtime_on_signal INT "smoke command"' INT
trap 'compose_runtime_on_signal TERM "smoke command"' TERM

[[ "${timeout_seconds}" =~ ^[1-9][0-9]*$ ]] || {
  echo "COMPOSE_SMOKE_TIMEOUT_SECONDS must be a positive integer" >&2
  exit 2
}
[[ "${backend_image}" == *@sha256:* ]] || {
  echo "BACKEND_IMAGE_REF must be an immutable repository@sha256 digest" >&2
  exit 2
}
[[ "$(id -u)" -ne 0 ]] || {
  echo "Compose runner must execute workflows as a non-root user" >&2
  exit 1
}
[[ ! -e /var/run/secrets/kubernetes.io/serviceaccount/token ]] || {
  echo "Compose runner unexpectedly has a Kubernetes service-account token" >&2
  exit 1
}
awk '$1 == 0 && $2 > 65535 && $3 >= 65536 { ok=1 } END { exit !ok }' \
  /proc/self/uid_map || {
    echo "Compose runner is not inside the expected Pod user namespace" >&2
    exit 1
  }

compose_runtime_snapshot "${results_dir}/runtime-before.txt"
# A hard-killed predecessor (Pod restart, SIGKILL past the traps) cannot run
# its own prune; reclaim its image layers here so one crash does not fail
# every later job on this runner. runtime-before.txt keeps the leak evidence.
compose_runtime_prune_images "${results_dir}/image-prune-before.log"
compose_runtime_assert_clean "before startup"
compose_runtime_compose config --format json >"${results_dir}/compose-config.json"
compose_runtime_require_digest_images "${results_dir}/compose-config.json"
resolved_backend="$(jq -er '.services.backend.image' "${results_dir}/compose-config.json")"
[[ "${resolved_backend}" == "${backend_image}" ]] || {
  echo "Compose backend ref mismatch: expected ${backend_image}, got ${resolved_backend}" >&2
  exit 1
}
compose_runtime_start_watchdog "${timeout_seconds}" Smoke
compose_runtime_registry_login \
  "${harbor_registry}" "${harbor_username}" "${harbor_password}" >/dev/null

pull_started="$(date +%s)"
compose_runtime_run_interruptible compose_runtime_compose pull \
  postgres backend trivy pki setup pypi-test npm-test cargo-test
pull_finished="$(date +%s)"

docker image inspect "${backend_image}" \
  --format 'id={{.Id}} repo_digests={{json .RepoDigests}}' \
  >"${results_dir}/backend-image.txt"

up_started="$(date +%s)"
compose_runtime_run_interruptible compose_runtime_compose up \
  --detach --no-build --wait postgres backend trivy pki setup
up_finished="$(date +%s)"

status=0
for test in pypi-test npm-test cargo-test; do
  test_started="$(date +%s)"
  set +e
  compose_runtime_run_interruptible bash -o pipefail -c \
    'docker compose --file "$1" --file "$2" --profile smoke run --no-deps --rm --name "$3" "$4" 2>&1 | tee -a "$5"' \
    _ "${compose_file}" "${override_file}" "${active_test_container}" "${test}" \
    "${results_dir}/smoke.log"
  test_rc=$?
  set -e
  test_finished="$(date +%s)"
  printf '%s_seconds=%s\n' "${test}" "$(( test_finished - test_started ))" \
    >>"${results_dir}/timings.env"
  if [[ "${test_rc}" -eq 0 ]]; then
    echo "PASS ${test}"
  else
    echo "FAIL ${test}" >&2
    status=1
  fi
done

{
  printf 'pull_seconds=%s\n' "$(( pull_finished - pull_started ))"
  printf 'compose_up_seconds=%s\n' "$(( up_finished - up_started ))"
  printf 'test_exit_code=%s\n' "${status}"
} >>"${results_dir}/timings.env"

exit "${status}"
