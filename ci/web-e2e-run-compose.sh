#!/usr/bin/env bash
# Run the focused browser E2E suite against exact signed backend/web digests
# and an immutable Playwright runner image. Application and test-image builds
# stay on rootless BuildKit; this script is runtime-only on Podman Compose.
set -euo pipefail

readonly root="$(git rev-parse --show-toplevel)"
readonly compose_file="${root}/artifact-keeper-web/docker-compose.e2e.yml"
readonly override_file="${root}/ci/web-e2e-compose.override.yml"
readonly backend_image="${BACKEND_IMAGE_REF:?BACKEND_IMAGE_REF is required}"
readonly web_image="${WEB_IMAGE_REF:?WEB_IMAGE_REF is required}"
readonly runner_image="${E2E_RUNNER_IMAGE:?E2E_RUNNER_IMAGE is required}"
readonly harbor_registry="${HARBOR_REGISTRY:?HARBOR_REGISTRY is required}"
readonly harbor_username="${HARBOR_USERNAME:?HARBOR_USERNAME is required}"
readonly harbor_password="${HARBOR_PASSWORD:?HARBOR_PASSWORD is required}"
readonly spec="${E2E_SPEC:-e2e/suites/interactions/integrations/peers.spec.ts}"
readonly project="${E2E_PROJECT:-interactions}"
readonly test_timeout_ms="${E2E_TEST_TIMEOUT_MS:-90000}"
readonly results_dir="${E2E_RESULTS_DIR:-/tmp/artifact-keeper-web-e2e}"
readonly timeout_seconds="${COMPOSE_E2E_TIMEOUT_SECONDS:-1500}"
readonly revision="$(git rev-parse --short=8 HEAD)"
readonly run_suffix="${GITEA_RUN_NUMBER:-${GITHUB_RUN_NUMBER:-0}}"
readonly runner_docker_config="${DOCKER_CONFIG:-${HOME}/.docker}"

export COMPOSE_PROJECT_NAME="ak-web-e2e-${revision}-${run_suffix}"
export E2E_NETWORK_NAME="${COMPOSE_PROJECT_NAME}-network"
export BACKEND_IMAGE_REF="${backend_image}"
export WEB_IMAGE_REF="${web_image}"
export E2E_RUNNER_IMAGE="${runner_image}"
export DOCKER_CONFIG="${TMPDIR:-/tmp}/${COMPOSE_PROJECT_NAME}-docker-config"

readonly test_container="${COMPOSE_PROJECT_NAME}-playwright"
child_pid=""
watchdog_pid=""
started_at="$(date +%s)"

rm -rf "${DOCKER_CONFIG}"
mkdir -p "${results_dir}" "${DOCKER_CONFIG}"
rm -rf "${results_dir:?}"/*
chmod 700 "${DOCKER_CONFIG}"
if [[ -f "${runner_docker_config}/config.json" ]]; then
  cp "${runner_docker_config}/config.json" "${DOCKER_CONFIG}/config.json"
fi
if [[ -d "${runner_docker_config}/cli-plugins" ]]; then
  ln -s "${runner_docker_config}/cli-plugins" "${DOCKER_CONFIG}/cli-plugins"
fi

compose() {
  docker compose --file "${compose_file}" --file "${override_file}" "$@"
}

runtime_snapshot() {
  local destination="$1"
  {
    printf 'captured_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'containers=%s\n' "$(docker ps -aq | wc -l | tr -d ' ')"
    printf 'volumes=%s\n' "$(docker volume ls -q | wc -l | tr -d ' ')"
    printf 'e2e_networks=%s\n' \
      "$(docker network ls --format '{{.Name}}' | grep -c "^${E2E_NETWORK_NAME}$" || true)"
    docker system df
  } >"${destination}" 2>&1
}

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  set +e
  [[ -z "${watchdog_pid}" ]] || kill "${watchdog_pid}" >/dev/null 2>&1 || true
  docker rm -f "${test_container}" >/dev/null 2>&1 || true
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
  local signal="$1" rc=143
  [[ "${signal}" != INT ]] || rc=130
  echo "Received ${signal}; terminating active web E2E command" >&2
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
  echo "COMPOSE_E2E_TIMEOUT_SECONDS must be a positive integer" >&2
  exit 2
}
for ref in "${backend_image}" "${web_image}" "${runner_image}"; do
  [[ "${ref}" == *@sha256:* ]] || {
    echo "all web E2E images must be immutable repository@sha256 refs: ${ref}" >&2
    exit 2
  }
done
[[ "$(id -u)" -ne 0 ]] || { echo "Compose runner must execute as non-root" >&2; exit 1; }
[[ ! -e /var/run/secrets/kubernetes.io/serviceaccount/token ]] || {
  echo "Compose runner unexpectedly has a Kubernetes service-account token" >&2
  exit 1
}
awk '$1 == 0 && $2 > 65535 && $3 >= 65536 { ok=1 } END { exit !ok }' \
  /proc/self/uid_map || { echo "Compose runner lacks the expected Pod user namespace" >&2; exit 1; }

runtime_snapshot "${results_dir}/runtime-before.txt"
compose config --format json >"${results_dir}/compose-config.json"
for pair in \
  "backend:${backend_image}" \
  "web:${web_image}" \
  "playwright:${runner_image}"; do
  service="${pair%%:*}"
  expected="${pair#*:}"
  actual="$(jq -er --arg service "${service}" '.services[$service].image' \
    "${results_dir}/compose-config.json")"
  [[ "${actual}" == "${expected}" ]] || {
    echo "Compose ${service} ref mismatch: expected ${expected}, got ${actual}" >&2
    exit 1
  }
done

printf '%s' "${harbor_password}" |
  docker login "${harbor_registry}" --username "${harbor_username}" --password-stdin >/dev/null

(
  sleep "${timeout_seconds}"
  echo "Web E2E watchdog reached ${timeout_seconds}s; requesting cleanup" >&2
  kill -TERM "$$"
) &
watchdog_pid=$!

pull_started="$(date +%s)"
run_interruptible compose pull postgres meilisearch backend web playwright
pull_finished="$(date +%s)"

for pair in \
  "backend:${backend_image}" \
  "web:${web_image}" \
  "playwright:${runner_image}"; do
  service="${pair%%:*}"
  image="${pair#*:}"
  docker image inspect "${image}" --format 'id={{.Id}} repo_digests={{json .RepoDigests}}' \
    >"${results_dir}/${service}-image.txt"
done

up_started="$(date +%s)"
run_interruptible compose up --detach --no-build --wait postgres meilisearch backend web
up_finished="$(date +%s)"

test_started="$(date +%s)"
set +e
run_interruptible bash -o pipefail -c \
  'docker compose --file "$1" --file "$2" run --name "$3" --no-deps playwright npx playwright test --project="$4" --timeout="$5" "$6" 2>&1 | tee "$7"' \
  _ "${compose_file}" "${override_file}" "${test_container}" "${project}" \
  "${test_timeout_ms}" "${spec}" "${results_dir}/playwright.log"
status=$?
set -e
test_finished="$(date +%s)"

docker cp "${test_container}:/work/playwright-report" "${results_dir}/playwright-report" \
  >/dev/null 2>&1 || true
docker cp "${test_container}:/work/test-results" "${results_dir}/test-results" \
  >/dev/null 2>&1 || true

{
  printf 'pull_seconds=%s\n' "$(( pull_finished - pull_started ))"
  printf 'compose_up_seconds=%s\n' "$(( up_finished - up_started ))"
  printf 'playwright_seconds=%s\n' "$(( test_finished - test_started ))"
  printf 'test_exit_code=%s\n' "${status}"
} >>"${results_dir}/timings.env"

[[ "${status}" -eq 0 ]] || { echo "web E2E suite failed (Playwright exit ${status})" >&2; exit "${status}"; }
echo "PASS web-e2e (${project}:${spec})"
