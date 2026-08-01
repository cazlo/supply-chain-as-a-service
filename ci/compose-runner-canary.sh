#!/usr/bin/env bash
# Upstream-parity Docker Compose + focused Playwright proof for the dedicated
# artifact-keeper-compose runner. This maintenance diagnostic deliberately
# consumes no publishing credentials; the publish workflow uses prebuilt,
# digest-pinned images rather than this canary's small compatibility builds.
set -euo pipefail

readonly root="$(git rev-parse --show-toplevel)"
readonly web="${root}/artifact-keeper-web"
readonly compose_file="${web}/docker-compose.e2e.yml"
readonly results_dir="${COMPOSE_CANARY_RESULTS_DIR:-${root}/.artifacts/compose-runner}"
readonly playwright_version="1.58.2"
readonly playwright_image="mcr.microsoft.com/playwright:v${playwright_version}-noble@sha256:6446946a1d9fd62d9ae501312a2d76a43ee688542b21622056a372959b65d63d"
readonly mode="${1:-}"
child_pid=""
watchdog_pid=""

export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-ak-compose-canary}"
export DOCKER_BUILDKIT=0
export COMPOSE_DOCKER_CLI_BUILD=0

mkdir -p "${results_dir}"

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  set +e
  if [[ -n "${watchdog_pid}" ]]; then
    kill "${watchdog_pid}" >/dev/null 2>&1 || true
    # Runner 3 bounds how long it waits for descendant-held stdout/stderr
    # pipes. Reap the watchdog after terminating it so its sleep process cannot
    # retain the step's output descriptors and trigger exec.ErrWaitDelay.
    wait "${watchdog_pid}" >/dev/null 2>&1 || true
    watchdog_pid=""
  fi
  docker rm -f ak-compose-canary-playwright >/dev/null 2>&1 || true
  if [[ "${mode}" != "--cleanup-only" || ! -e "${results_dir}/compose.log" ]]; then
    docker compose -f "${compose_file}" ps --all >"${results_dir}/compose-ps.txt" 2>&1
    docker compose -f "${compose_file}" logs --no-color >"${results_dir}/compose.log" 2>&1
  fi
  local down_log="${results_dir}/compose-down.log"
  [[ "${mode}" != "--cleanup-only" ]] || down_log="${results_dir}/compose-down-final.log"
  docker compose -f "${compose_file}" down -v --remove-orphans \
    >"${down_log}" 2>&1
  {
    printf 'containers=%s\n' "$(docker ps -aq | wc -l | tr -d ' ')"
    printf 'volumes=%s\n' "$(docker volume ls -q | wc -l | tr -d ' ')"
    printf 'compose_networks=%s\n' \
      "$(docker network ls --format '{{.Name}}' | grep -c '^ak-e2e-network$' || true)"
    docker system df
  } >"${results_dir}/runtime-after-cleanup.txt" 2>&1
  exit "${rc}"
}
trap cleanup EXIT

on_signal() {
  local signal="$1"
  local rc=143
  [[ "${signal}" != INT ]] || rc=130
  echo "Received ${signal}; terminating active canary command" >&2
  if [[ -n "${child_pid}" ]]; then
    kill -TERM "${child_pid}" >/dev/null 2>&1 || true
    # Docker/Compose clients may defer TERM while attached to a pull or inner
    # process. Bound that grace period so EXIT cleanup can force-remove the
    # named Playwright container and tear the Compose project down promptly.
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

if [[ "${mode}" == "--cleanup-only" ]]; then
  exit 0
fi

readonly canary_timeout_seconds="${COMPOSE_CANARY_TIMEOUT_SECONDS:-1500}"
[[ "${canary_timeout_seconds}" =~ ^[1-9][0-9]*$ ]] || {
  echo "COMPOSE_CANARY_TIMEOUT_SECONDS must be a positive integer" >&2
  exit 2
}
(
  sleep "${canary_timeout_seconds}"
  echo "Canary watchdog reached ${canary_timeout_seconds}s; requesting cleanup" >&2
  kill -TERM "$$"
) >"${results_dir}/watchdog.log" 2>&1 &
watchdog_pid=$!

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
    cat /proc/self/uid_map >&2
    exit 1
  }

docker version
docker info
docker compose version

resolved_playwright_version="$(jq -r \
  '.packages["node_modules/@playwright/test"].version' \
  "${web}/package-lock.json")"
[[ "${resolved_playwright_version}" == "${playwright_version}" ]] || {
  echo "vendored @playwright/test is ${resolved_playwright_version}; re-pin the canary browser image from ${playwright_version}" >&2
  exit 1
}

cd "${web}"
run_interruptible docker compose -f "${compose_file}" up -d --build --wait

# The runner image is intentionally Alpine and does not carry browser system
# libraries. Run the matching, digest-pinned Playwright image through the same
# Podman API. --network host reaches the Compose-published localhost:3100 port
# in the outer Pod network namespace; UID/GID parity keeps reports writable by
# the non-root workflow process.
set +e
run_interruptible docker run --rm \
  --name ak-compose-canary-playwright \
  --network host \
  --ipc host \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  -e CI=true \
  -e PLAYWRIGHT_BASE_URL=http://127.0.0.1:3100 \
  -v "${web}:/work" \
  -w /work \
  "${playwright_image}" \
  bash -lc 'npm ci --no-audit --no-fund && npx playwright test --project=interactions e2e/suites/interactions/integrations/peers.spec.ts'
test_rc=$?
set -e

for path in playwright-report test-results; do
  if [[ -e "${web}/${path}" ]]; then
    cp -R "${web}/${path}" "${results_dir}/${path}"
  fi
done

exit "${test_rc}"
