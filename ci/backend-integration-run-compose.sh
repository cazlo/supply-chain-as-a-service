#!/usr/bin/env bash
# Run one pre-built backend integration-test binary against an isolated
# Compose Postgres on the dedicated Podman runner. Rust compilation stays on
# backend-integration-build's persistent BuildKit runner.
set -euo pipefail

readonly root="$(git rev-parse --show-toplevel)"
readonly compose_file="${root}/ci/backend-integration-compose.yml"
readonly test_target="${TEST:?TEST=<backend/tests/*.rs target> is required}"
readonly image="${TEST_RUNNER_IMAGE:?TEST_RUNNER_IMAGE is required}"
readonly harbor_registry="${HARBOR_REGISTRY:?HARBOR_REGISTRY is required}"
readonly harbor_username="${HARBOR_USERNAME:?HARBOR_USERNAME is required}"
readonly harbor_password="${HARBOR_PASSWORD:?HARBOR_PASSWORD is required}"
readonly revision="$(git rev-parse --short=8 HEAD)"
readonly run_suffix="${GITEA_RUN_NUMBER:-${GITHUB_RUN_NUMBER:-0}}"
readonly results_dir="${QUALITY_RESULTS_DIR:-/tmp/artifact-keeper-integration-${test_target}}"
readonly timeout_seconds="${COMPOSE_INTEGRATION_TIMEOUT_SECONDS:-600}"
readonly runner_docker_config="${DOCKER_CONFIG:-${HOME}/.docker}"
readonly cleanup_timeout_seconds="${COMPOSE_CLEANUP_COMMAND_TIMEOUT_SECONDS:-30}"
readonly postgres_image="docker.io/library/postgres:16-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777"

safe_target="${test_target//_/-}"
run_id="${GITEA_RUN_ID:-${GITHUB_RUN_ID:-${run_suffix}}}"
run_attempt="${GITEA_RUN_ATTEMPT:-${GITHUB_RUN_ATTEMPT:-1}}"
export COMPOSE_PROJECT_NAME="$(printf '%s' "ak-int-${revision}-${run_id}-${run_attempt}-${safe_target}" | cut -c1-63)"
export TEST_RUNNER_IMAGE="${image}"
export TEST_TARGET="${test_target}"
export INTEGRATION_POSTGRES_IMAGE="${postgres_image}"

readonly test_container="${COMPOSE_PROJECT_NAME}-test-run"
readonly docker_config="${TMPDIR:-/tmp}/${COMPOSE_PROJECT_NAME}-docker-config"

COMPOSE_RUNTIME_RESULTS_DIR="${results_dir}"
COMPOSE_RUNTIME_DOCKER_CONFIG="${docker_config}"
COMPOSE_RUNTIME_RUNNER_DOCKER_CONFIG="${runner_docker_config}"
COMPOSE_RUNTIME_TEST_CONTAINER="${test_container}"
COMPOSE_RUNTIME_NETWORK_PATTERN="^${COMPOSE_PROJECT_NAME}_"
COMPOSE_RUNTIME_CLEANUP_COMMAND_TIMEOUT_SECONDS="${cleanup_timeout_seconds}"
COMPOSE_RUNTIME_COMPOSE_ARGS=(-f "${compose_file}")
# shellcheck source=ci/compose-runtime-lib.sh
source "${root}/ci/compose-runtime-lib.sh"
compose_runtime_init

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  compose_runtime_finalize "${rc}"
  exit $?
}
trap cleanup EXIT

trap 'compose_runtime_on_signal INT "integration command"' INT
trap 'compose_runtime_on_signal TERM "integration command"' TERM

[[ "${timeout_seconds}" =~ ^[1-9][0-9]*$ ]] || {
  echo "COMPOSE_INTEGRATION_TIMEOUT_SECONDS must be a positive integer" >&2
  exit 2
}
[[ "${image}" == *@sha256:* ]] || {
  echo "TEST_RUNNER_IMAGE must be an immutable repository@sha256 digest" >&2
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

compose_runtime_snapshot "${results_dir}/runtime-before.txt"
# A hard-killed predecessor (Pod restart, SIGKILL past the traps) cannot run
# its own cleanup; re-enforce the image budget here so one crash does not
# fail every later job on this runner. Warm images within budget are kept —
# runtime-before.txt records what was found either way.
compose_runtime_enforce_image_budget "${results_dir}/image-budget-before.log"
compose_runtime_assert_clean "before startup"
compose_runtime_compose config --format json >"${results_dir}/compose-config.json"
compose_runtime_require_digest_images "${results_dir}/compose-config.json"
compose_runtime_start_watchdog "${timeout_seconds}" Integration
compose_runtime_registry_login \
  "${harbor_registry}" "${harbor_username}" "${harbor_password}" >/dev/null

pull_started="$(date +%s)"
compose_runtime_run_interruptible compose_runtime_compose pull
pull_finished="$(date +%s)"

up_started="$(date +%s)"
compose_runtime_run_interruptible compose_runtime_compose up -d db --wait
up_finished="$(date +%s)"

docker image inspect "${image}" \
  --format 'id={{.Id}} repo_digests={{json .RepoDigests}}' \
  >"${results_dir}/test-image.txt"
docker image inspect "${postgres_image}" \
  --format 'id={{.Id}} repo_digests={{json .RepoDigests}}' \
  >"${results_dir}/postgres-image.txt"

test_started="$(date +%s)"
set +e
compose_runtime_run_interruptible bash -o pipefail -c \
  'docker compose -f "$1" run --rm --name "$2" --no-deps test 2>&1 | tee "$3"' \
  _ "${compose_file}" "${test_container}" "${results_dir}/integration.log"
test_rc=$?
set -e
test_finished="$(date +%s)"

{
  printf 'pull_seconds=%s\n' "$(( pull_finished - pull_started ))"
  printf 'compose_up_seconds=%s\n' "$(( up_finished - up_started ))"
  printf 'test_seconds=%s\n' "$(( test_finished - test_started ))"
  printf 'test_exit_code=%s\n' "${test_rc}"
} >"${results_dir}/timings.env"

exit "${test_rc}"
