#!/usr/bin/env bash
# Shared lifecycle primitives for the dedicated Podman Compose runner.
# Callers own their scenario-specific pull/up/test steps and provide the
# COMPOSE_RUNTIME_* variables consumed below.

compose_runtime_compose() {
  docker compose "${COMPOSE_RUNTIME_COMPOSE_ARGS[@]}" "$@"
}

compose_runtime_bounded() {
  timeout -s TERM -k 5 \
    "${COMPOSE_RUNTIME_CLEANUP_COMMAND_TIMEOUT_SECONDS:-30}" "$@"
}

compose_runtime_bounded_compose() {
  compose_runtime_bounded docker compose \
    "${COMPOSE_RUNTIME_COMPOSE_ARGS[@]}" "$@"
}

# Pruning tens of GiB of overlay layers can exceed the per-command cleanup
# bound, so image removal gets its own, longer timeout.
compose_runtime_bounded_prune() {
  timeout -s TERM -k 5 \
    "${COMPOSE_RUNTIME_IMAGE_PRUNE_TIMEOUT_SECONDS:-120}" "$@"
}

compose_runtime_registry_login() {
  local runtime_registry="$1"
  local runtime_registry_username="$2"
  local runtime_registry_password="$3"

  printf '%s' "${runtime_registry_password}" |
    compose_runtime_bounded docker login "${runtime_registry}" \
      --username "${runtime_registry_username}" --password-stdin
}

compose_runtime_init() {
  : "${COMPOSE_RUNTIME_RESULTS_DIR:?COMPOSE_RUNTIME_RESULTS_DIR is required}"
  : "${COMPOSE_RUNTIME_DOCKER_CONFIG:?COMPOSE_RUNTIME_DOCKER_CONFIG is required}"
  : "${COMPOSE_RUNTIME_RUNNER_DOCKER_CONFIG:?COMPOSE_RUNTIME_RUNNER_DOCKER_CONFIG is required}"
  : "${COMPOSE_RUNTIME_TEST_CONTAINER:?COMPOSE_RUNTIME_TEST_CONTAINER is required}"
  : "${COMPOSE_RUNTIME_NETWORK_PATTERN:?COMPOSE_RUNTIME_NETWORK_PATTERN is required}"

  command -v timeout >/dev/null || {
    echo "Compose runner requires the timeout utility for bounded cleanup" >&2
    return 1
  }
  [[ "${COMPOSE_RUNTIME_CLEANUP_COMMAND_TIMEOUT_SECONDS:-30}" =~ ^[1-9][0-9]*$ ]] || {
    echo "COMPOSE_CLEANUP_COMMAND_TIMEOUT_SECONDS must be a positive integer" >&2
    return 1
  }
  [[ "${COMPOSE_RUNTIME_IMAGE_PRUNE_TIMEOUT_SECONDS:-120}" =~ ^[1-9][0-9]*$ ]] || {
    echo "COMPOSE_IMAGE_PRUNE_TIMEOUT_SECONDS must be a positive integer" >&2
    return 1
  }

  COMPOSE_RUNTIME_CHILD_PID=""
  COMPOSE_RUNTIME_WATCHDOG_PID=""
  COMPOSE_RUNTIME_STARTED_AT="$(date +%s)"

  mkdir -p "${COMPOSE_RUNTIME_RESULTS_DIR}"
  find "${COMPOSE_RUNTIME_RESULTS_DIR}" -mindepth 1 -maxdepth 1 \
    -exec rm -rf -- {} +

  rm -rf "${COMPOSE_RUNTIME_DOCKER_CONFIG}"
  mkdir -p "${COMPOSE_RUNTIME_DOCKER_CONFIG}"
  chmod 700 "${COMPOSE_RUNTIME_DOCKER_CONFIG}"
  if [[ -f "${COMPOSE_RUNTIME_RUNNER_DOCKER_CONFIG}/config.json" ]]; then
    cp "${COMPOSE_RUNTIME_RUNNER_DOCKER_CONFIG}/config.json" \
      "${COMPOSE_RUNTIME_DOCKER_CONFIG}/config.json"
  fi
  if [[ -d "${COMPOSE_RUNTIME_RUNNER_DOCKER_CONFIG}/cli-plugins" ]]; then
    ln -s "${COMPOSE_RUNTIME_RUNNER_DOCKER_CONFIG}/cli-plugins" \
      "${COMPOSE_RUNTIME_DOCKER_CONFIG}/cli-plugins"
  fi
  export DOCKER_CONFIG="${COMPOSE_RUNTIME_DOCKER_CONFIG}"
}

compose_runtime_collect_state() {
  local container_ids volume_names network_names image_ids
  local containers volumes project_networks images

  container_ids="$(compose_runtime_bounded docker ps -aq)" || return 1
  volume_names="$(compose_runtime_bounded docker volume ls -q)" || return 1
  network_names="$(compose_runtime_bounded docker network ls --format '{{.Name}}')" || return 1
  image_ids="$(compose_runtime_bounded docker image ls -aq)" || return 1

  containers="$(awk 'NF { count++ } END { print count + 0 }' <<<"${container_ids}")"
  volumes="$(awk 'NF { count++ } END { print count + 0 }' <<<"${volume_names}")"
  project_networks="$(awk -v pattern="${COMPOSE_RUNTIME_NETWORK_PATTERN}" \
    '$0 ~ pattern { count++ } END { print count + 0 }' <<<"${network_names}")"
  images="$(awk 'NF { count++ } END { print count + 0 }' <<<"${image_ids}")"

  printf 'captured_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'containers=%s\n' "${containers}"
  printf 'volumes=%s\n' "${volumes}"
  printf 'project_networks=%s\n' "${project_networks}"
  printf 'images=%s\n' "${images}"
}

compose_runtime_snapshot() {
  local destination="$1"
  compose_runtime_collect_state >"${destination}" || return 1
  if ! compose_runtime_bounded docker system df >>"${destination}" 2>&1; then
    echo "docker_system_df=unavailable" >>"${destination}"
  fi
}

compose_runtime_assert_clean() {
  local context="$1"
  local state containers volumes project_networks images

  state="$(compose_runtime_collect_state)" || {
    echo "Unable to inspect the Podman engine ${context}" >&2
    return 1
  }
  containers="$(awk -F= '$1 == "containers" { print $2 }' <<<"${state}")"
  volumes="$(awk -F= '$1 == "volumes" { print $2 }' <<<"${state}")"
  project_networks="$(awk -F= '$1 == "project_networks" { print $2 }' <<<"${state}")"
  images="$(awk -F= '$1 == "images" { print $2 }' <<<"${state}")"

  if [[ "${containers}" != 0 || "${volumes}" != 0 || "${project_networks}" != 0 || "${images}" != 0 ]]; then
    echo "Compose engine is not clean ${context}: containers=${containers}, volumes=${volumes}, project_networks=${project_networks}, images=${images}" >&2
    return 1
  fi
}

# Podman keeps image layers after `compose down`, and on a long-lived
# capacity-one runner the per-PR digests accumulate until the podman-graph
# EmptyDir breaches its limit and the kubelet evicts the Pod mid-job (the
# Gitea job then hangs server-side, because job timeouts are runner-enforced).
# Every job therefore starts from and returns to an empty image store; the
# re-pull cost is repo-local Harbor traffic and is recorded in timings.env.
compose_runtime_prune_images() {
  local log_file="$1"
  compose_runtime_bounded_prune docker image prune -af >"${log_file}" 2>&1
}

compose_runtime_require_digest_images() {
  local config_file="$1"
  if ! jq -e '
    all(.services | to_entries[];
      ((.value.image // "") | test("@sha256:[0-9a-f]{64}$")))
  ' "${config_file}" >/dev/null; then
    echo "Every Compose runtime image must be pinned by sha256 digest:" >&2
    jq -r '.services | to_entries[] | select(((.value.image // "") | test("@sha256:[0-9a-f]{64}$")) | not) | "  \(.key): \(.value.image // "<missing>")"' \
      "${config_file}" >&2
    return 1
  fi
}

compose_runtime_run_interruptible() {
  "$@" &
  COMPOSE_RUNTIME_CHILD_PID=$!
  set +e
  wait "${COMPOSE_RUNTIME_CHILD_PID}"
  local rc=$?
  set -e
  COMPOSE_RUNTIME_CHILD_PID=""
  return "${rc}"
}

compose_runtime_on_signal() {
  local signal="$1"
  local description="$2"
  local rc=143
  [[ "${signal}" != INT ]] || rc=130
  echo "Received ${signal}; terminating active ${description}" >&2
  if [[ -n "${COMPOSE_RUNTIME_CHILD_PID}" ]]; then
    kill -TERM "${COMPOSE_RUNTIME_CHILD_PID}" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
      kill -0 "${COMPOSE_RUNTIME_CHILD_PID}" >/dev/null 2>&1 || break
      sleep 0.1
    done
    kill -KILL "${COMPOSE_RUNTIME_CHILD_PID}" >/dev/null 2>&1 || true
  fi
  exit "${rc}"
}

compose_runtime_start_watchdog() {
  local runtime_watchdog_seconds="$1"
  local runtime_watchdog_description="$2"
  (
    sleep "${runtime_watchdog_seconds}"
    echo "${runtime_watchdog_description} watchdog reached ${runtime_watchdog_seconds}s; requesting cleanup" >&2
    kill -TERM "$$"
  ) >"${COMPOSE_RUNTIME_RESULTS_DIR}/watchdog.log" 2>&1 &
  COMPOSE_RUNTIME_WATCHDOG_PID=$!
}

compose_runtime_stop_watchdog() {
  if [[ -n "${COMPOSE_RUNTIME_WATCHDOG_PID}" ]]; then
    kill "${COMPOSE_RUNTIME_WATCHDOG_PID}" >/dev/null 2>&1 || true
    wait "${COMPOSE_RUNTIME_WATCHDOG_PID}" >/dev/null 2>&1 || true
    COMPOSE_RUNTIME_WATCHDOG_PID=""
  fi
}

compose_runtime_finalize() {
  local original_rc="$1"
  local cleanup_failed=0
  local down_started down_finished final_rc

  set +e
  compose_runtime_stop_watchdog

  # Removing config.json revokes the job's registry credential material before
  # any potentially hanging API cleanup. Keep cli-plugins until Compose exits.
  rm -f "${COMPOSE_RUNTIME_DOCKER_CONFIG}/config.json"

  compose_runtime_bounded docker rm -fv "${COMPOSE_RUNTIME_TEST_CONTAINER}" \
    >/dev/null 2>&1 || true
  compose_runtime_bounded_compose ps --all \
    >"${COMPOSE_RUNTIME_RESULTS_DIR}/compose-ps.txt" 2>&1 || true
  compose_runtime_bounded_compose logs --no-color \
    >"${COMPOSE_RUNTIME_RESULTS_DIR}/compose.log" 2>&1 || true

  # Peak graph usage for this job: the EmptyDir sizing evidence the runner
  # limits are derived from lives here, not in the post-cleanup snapshot.
  compose_runtime_snapshot \
    "${COMPOSE_RUNTIME_RESULTS_DIR}/runtime-peak.txt" || true

  down_started="$(date +%s)"
  if ! compose_runtime_bounded_compose down --volumes --remove-orphans \
    >"${COMPOSE_RUNTIME_RESULTS_DIR}/compose-down.log" 2>&1; then
    echo "Bounded Compose teardown failed" >&2
    cleanup_failed=1
  fi
  if ! compose_runtime_prune_images \
    "${COMPOSE_RUNTIME_RESULTS_DIR}/image-prune.log"; then
    echo "Bounded image prune failed" >&2
    cleanup_failed=1
  fi
  down_finished="$(date +%s)"

  if ! compose_runtime_snapshot \
    "${COMPOSE_RUNTIME_RESULTS_DIR}/runtime-after-cleanup.txt"; then
    echo "Unable to capture post-cleanup runtime state" >&2
    cleanup_failed=1
  fi
  if ! compose_runtime_assert_clean "after cleanup"; then
    cleanup_failed=1
  fi

  rm -rf "${COMPOSE_RUNTIME_DOCKER_CONFIG}"
  {
    printf 'started_epoch=%s\n' "${COMPOSE_RUNTIME_STARTED_AT}"
    printf 'cleanup_started_epoch=%s\n' "${down_started}"
    printf 'cleanup_finished_epoch=%s\n' "${down_finished}"
    printf 'total_seconds=%s\n' "$(( down_finished - COMPOSE_RUNTIME_STARTED_AT ))"
    printf 'cleanup_seconds=%s\n' "$(( down_finished - down_started ))"
    printf 'cleanup_exit_code=%s\n' "${cleanup_failed}"
  } >>"${COMPOSE_RUNTIME_RESULTS_DIR}/timings.env"

  final_rc="${original_rc}"
  if [[ "${final_rc}" -eq 0 && "${cleanup_failed}" -ne 0 ]]; then
    final_rc=1
  fi
  return "${final_rc}"
}
