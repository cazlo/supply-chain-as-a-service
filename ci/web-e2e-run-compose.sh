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
readonly cleanup_timeout_seconds="${COMPOSE_CLEANUP_COMMAND_TIMEOUT_SECONDS:-30}"

run_id="${GITEA_RUN_ID:-${GITHUB_RUN_ID:-${run_suffix}}}"
run_attempt="${GITEA_RUN_ATTEMPT:-${GITHUB_RUN_ATTEMPT:-1}}"
export COMPOSE_PROJECT_NAME="ak-web-e2e-${revision}-${run_id}-${run_attempt}"
export E2E_NETWORK_NAME="${COMPOSE_PROJECT_NAME}-network"
export BACKEND_IMAGE_REF="${backend_image}"
export WEB_IMAGE_REF="${web_image}"
export E2E_RUNNER_IMAGE="${runner_image}"

readonly test_container="${COMPOSE_PROJECT_NAME}-playwright"
readonly docker_config="${TMPDIR:-/tmp}/${COMPOSE_PROJECT_NAME}-docker-config"

COMPOSE_RUNTIME_RESULTS_DIR="${results_dir}"
COMPOSE_RUNTIME_DOCKER_CONFIG="${docker_config}"
COMPOSE_RUNTIME_RUNNER_DOCKER_CONFIG="${runner_docker_config}"
COMPOSE_RUNTIME_TEST_CONTAINER="${test_container}"
COMPOSE_RUNTIME_NETWORK_PATTERN="^${E2E_NETWORK_NAME}$"
COMPOSE_RUNTIME_CLEANUP_COMMAND_TIMEOUT_SECONDS="${cleanup_timeout_seconds}"
COMPOSE_RUNTIME_COMPOSE_ARGS=(--file "${compose_file}" --file "${override_file}")
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

trap 'compose_runtime_on_signal INT "web E2E command"' INT
trap 'compose_runtime_on_signal TERM "web E2E command"' TERM

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

compose_runtime_snapshot "${results_dir}/runtime-before.txt"
# A hard-killed predecessor (Pod restart, SIGKILL past the traps) cannot run
# its own prune; reclaim its image layers here so one crash does not fail
# every later job on this runner. runtime-before.txt keeps the leak evidence.
compose_runtime_prune_images "${results_dir}/image-prune-before.log"
compose_runtime_assert_clean "before startup"
compose_runtime_compose config --format json >"${results_dir}/compose-config.json"
compose_runtime_require_digest_images "${results_dir}/compose-config.json"
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

compose_runtime_start_watchdog "${timeout_seconds}" "Web E2E"
compose_runtime_registry_login \
  "${harbor_registry}" "${harbor_username}" "${harbor_password}" >/dev/null

pull_started="$(date +%s)"
compose_runtime_run_interruptible compose_runtime_compose pull \
  postgres meilisearch backend web playwright
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
compose_runtime_run_interruptible compose_runtime_compose up \
  --detach --no-build --wait postgres meilisearch backend web
up_finished="$(date +%s)"

test_started="$(date +%s)"
set +e
compose_runtime_run_interruptible bash -o pipefail -c \
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
