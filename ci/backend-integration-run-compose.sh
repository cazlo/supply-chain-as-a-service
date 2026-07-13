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

safe_target="${test_target//_/-}"
export COMPOSE_PROJECT_NAME="$(printf '%s' "ak-int-${revision}-${run_suffix}-${safe_target}" | cut -c1-63)"
export TEST_RUNNER_IMAGE="${image}"
export TEST_TARGET="${test_target}"
export DOCKER_CONFIG="${TMPDIR:-/tmp}/${COMPOSE_PROJECT_NAME}-docker-config"

readonly test_container="${COMPOSE_PROJECT_NAME}-test-run"
child_pid=""
watchdog_pid=""
started_at="$(date +%s)"

mkdir -p "${results_dir}"
rm -f "${results_dir}"/*
rm -rf "${DOCKER_CONFIG}"
mkdir -p "${DOCKER_CONFIG}"
chmod 700 "${DOCKER_CONFIG}"
if [[ -f "${runner_docker_config}/config.json" ]]; then
  cp "${runner_docker_config}/config.json" "${DOCKER_CONFIG}/config.json"
fi
if [[ -d "${runner_docker_config}/cli-plugins" ]]; then
  ln -s "${runner_docker_config}/cli-plugins" "${DOCKER_CONFIG}/cli-plugins"
fi

runtime_snapshot() {
  local destination="$1"
  {
    printf 'captured_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'containers=%s\n' "$(docker ps -aq | wc -l | tr -d ' ')"
    printf 'volumes=%s\n' "$(docker volume ls -q | wc -l | tr -d ' ')"
    printf 'project_networks=%s\n' \
      "$(docker network ls --format '{{.Name}}' | grep -c "^${COMPOSE_PROJECT_NAME}_" || true)"
    docker system df
  } >"${destination}" 2>&1
}

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  set +e
  [[ -z "${watchdog_pid}" ]] || kill "${watchdog_pid}" >/dev/null 2>&1 || true
  docker rm -f "${test_container}" >/dev/null 2>&1 || true
  docker compose -f "${compose_file}" ps --all >"${results_dir}/compose-ps.txt" 2>&1
  docker compose -f "${compose_file}" logs --no-color >"${results_dir}/compose.log" 2>&1
  down_started="$(date +%s)"
  docker compose -f "${compose_file}" down -v --remove-orphans \
    >"${results_dir}/compose-down.log" 2>&1
  down_finished="$(date +%s)"
  runtime_snapshot "${results_dir}/runtime-after-cleanup.txt"
  docker logout "${harbor_registry}" >/dev/null 2>&1 || true
  rm -rf "${DOCKER_CONFIG}"
  {
    printf 'started_epoch=%s\n' "${started_at}"
    printf 'cleanup_started_epoch=%s\n' "${down_started}"
    printf 'cleanup_finished_epoch=%s\n' "${down_finished}"
    printf 'total_seconds=%s\n' "$(( down_finished - started_at ))"
    printf 'cleanup_seconds=%s\n' "$(( down_finished - down_started ))"
  } >>"${results_dir}/timings.env"
  exit "${rc}"
}
trap cleanup EXIT

on_signal() {
  local signal="$1"
  local rc=143
  [[ "${signal}" != INT ]] || rc=130
  echo "Received ${signal}; terminating active integration command" >&2
  if [[ -n "${child_pid}" ]]; then
    kill -TERM "${child_pid}" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
      kill -0 "${child_pid}" >/dev/null 2>&1 || break
      sleep 0.1
    done
    kill -KILL "${child_pid}" >/dev/null 2>&1 || true
  fi
  exit "${rc}"
}
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM

run_interruptible() {
  "$@" &
  child_pid=$!
  set +e
  wait "${child_pid}"
  local rc=$?
  set -e
  child_pid=""
  return "${rc}"
}

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

runtime_snapshot "${results_dir}/runtime-before.txt"
printf '%s' "${harbor_password}" |
  docker login "${harbor_registry}" --username "${harbor_username}" --password-stdin >/dev/null

(
  sleep "${timeout_seconds}"
  echo "Integration watchdog reached ${timeout_seconds}s; requesting cleanup" >&2
  kill -TERM "$$"
) &
watchdog_pid=$!

pull_started="$(date +%s)"
run_interruptible docker compose -f "${compose_file}" pull
pull_finished="$(date +%s)"

up_started="$(date +%s)"
run_interruptible docker compose -f "${compose_file}" up -d db --wait
up_finished="$(date +%s)"

docker image inspect "${image}" \
  --format 'id={{.Id}} repo_digests={{json .RepoDigests}}' \
  >"${results_dir}/test-image.txt"
docker image inspect postgres:16-alpine \
  --format 'id={{.Id}} repo_digests={{json .RepoDigests}}' \
  >"${results_dir}/postgres-image.txt"

test_started="$(date +%s)"
set +e
run_interruptible bash -o pipefail -c \
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
