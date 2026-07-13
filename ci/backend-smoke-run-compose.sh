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

export COMPOSE_PROJECT_NAME="ak-smoke-${revision}-${run_suffix}"
export SMOKE_CONTAINER_PREFIX="${COMPOSE_PROJECT_NAME}"
export SMOKE_NETWORK_NAME="${COMPOSE_PROJECT_NAME}-network"
export BACKEND_IMAGE_REF="${backend_image}"
export DOCKER_CONFIG="${TMPDIR:-/tmp}/${COMPOSE_PROJECT_NAME}-docker-config"

readonly active_test_container="${COMPOSE_PROJECT_NAME}-active-test"
child_pid=""
watchdog_pid=""
started_at="$(date +%s)"

rm -rf "${DOCKER_CONFIG}"
mkdir -p "${results_dir}" "${DOCKER_CONFIG}" "${root}/artifact-keeper/.pki"
rm -f "${results_dir}"/*
chmod 700 "${DOCKER_CONFIG}"
if [[ -f "${runner_docker_config}/config.json" ]]; then
  cp "${runner_docker_config}/config.json" "${DOCKER_CONFIG}/config.json"
fi
if [[ -d "${runner_docker_config}/cli-plugins" ]]; then
  ln -s "${runner_docker_config}/cli-plugins" "${DOCKER_CONFIG}/cli-plugins"
fi

compose() {
  docker compose \
    --file "${compose_file}" \
    --file "${override_file}" \
    --profile smoke \
    "$@"
}

runtime_snapshot() {
  local destination="$1"
  {
    printf 'captured_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'containers=%s\n' "$(docker ps -aq | wc -l | tr -d ' ')"
    printf 'volumes=%s\n' "$(docker volume ls -q | wc -l | tr -d ' ')"
    printf 'smoke_networks=%s\n' \
      "$(docker network ls --format '{{.Name}}' | grep -c "^${SMOKE_NETWORK_NAME}$" || true)"
    docker system df
  } >"${destination}" 2>&1
}

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  set +e
  [[ -z "${watchdog_pid}" ]] || kill "${watchdog_pid}" >/dev/null 2>&1 || true
  docker rm -f "${active_test_container}" >/dev/null 2>&1 || true
  compose ps --all >"${results_dir}/compose-ps.txt" 2>&1
  compose logs --no-color >"${results_dir}/compose.log" 2>&1
  down_started="$(date +%s)"
  compose down --volumes --remove-orphans >"${results_dir}/compose-down.log" 2>&1
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
  echo "Received ${signal}; terminating active smoke command" >&2
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

runtime_snapshot "${results_dir}/runtime-before.txt"
compose config --format json >"${results_dir}/compose-config.json"
resolved_backend="$(jq -er '.services.backend.image' "${results_dir}/compose-config.json")"
[[ "${resolved_backend}" == "${backend_image}" ]] || {
  echo "Compose backend ref mismatch: expected ${backend_image}, got ${resolved_backend}" >&2
  exit 1
}
printf '%s' "${harbor_password}" |
  docker login "${harbor_registry}" --username "${harbor_username}" --password-stdin >/dev/null

(
  sleep "${timeout_seconds}"
  echo "Smoke watchdog reached ${timeout_seconds}s; requesting cleanup" >&2
  kill -TERM "$$"
) &
watchdog_pid=$!

pull_started="$(date +%s)"
run_interruptible compose pull postgres backend trivy pki setup pypi-test npm-test cargo-test
pull_finished="$(date +%s)"

docker image inspect "${backend_image}" \
  --format 'id={{.Id}} repo_digests={{json .RepoDigests}}' \
  >"${results_dir}/backend-image.txt"

up_started="$(date +%s)"
run_interruptible compose up --detach --no-build --wait postgres backend trivy pki setup
up_finished="$(date +%s)"

status=0
for test in pypi-test npm-test cargo-test; do
  test_started="$(date +%s)"
  set +e
  run_interruptible bash -o pipefail -c \
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
