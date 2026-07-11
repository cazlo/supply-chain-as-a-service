#!/usr/bin/env bash
# Run DB-backed integration suites or upstream-equivalent coverage gates on a
# daemonless Gitea runner. PostgreSQL lives briefly in the runner's
# RBAC-confined ak-smoke namespace; compilation/tests run in rootless BuildKit.
set -euo pipefail

readonly root="$(git rev-parse --show-toplevel)"
readonly namespace="${QUALITY_NAMESPACE:-ak-smoke}"
readonly revision="$(git -C "${root}" rev-parse --short=8 HEAD)"
readonly run_suffix="${GITEA_RUN_NUMBER:-${GITHUB_RUN_NUMBER:-0}}"
readonly mode="${QUALITY_MODE:-coverage}"
case "${mode}" in
  integration|coverage) ;;
  *) echo "QUALITY_MODE must be integration or coverage" >&2; exit 2 ;;
esac
readonly test_target="${TEST:-}"
if [[ "${mode}" == "integration" && -z "${test_target}" ]]; then
  echo "TEST=<backend/tests/*.rs target> is required when QUALITY_MODE=integration" >&2
  exit 2
fi
# Deployment/service name must stay a valid k8s DNS-1035 label. Suffix it with
# the sanitized test target so concurrent integration matrix legs (one
# Postgres deployment per `backend/tests/*.rs` target) never collide on the
# same resource name in the shared ak-smoke namespace.
name_suffix="${test_target//_/-}"
name="$(printf '%s' "ak-${mode}-${revision}-${run_suffix}${name_suffix:+-${name_suffix}}" | cut -c1-63)"
readonly name="${name%-}"
readonly results_dir="${QUALITY_RESULTS_DIR:-/tmp/artifact-keeper-quality}"

cleanup() {
  kubectl -n "${namespace}" delete service,deployment "${name}" \
    --ignore-not-found --wait=true >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p "${results_dir}"
rm -f "${results_dir}/integration.log" \
  "${results_dir}/coverage.log" "${results_dir}/lcov.info"

cleanup
kubectl -n "${namespace}" apply -f - <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${name}
  labels: { app: ${name} }
spec:
  replicas: 1
  selector:
    matchLabels: { app: ${name} }
  template:
    metadata:
      labels: { app: ${name} }
    spec:
      # Pin the test DB to the jarvis builders' node. Unpinned, the scheduler
      # routinely placed it on the skynet nodes while tests ran on jarvis:
      # every query paid LAN RTT, and worse, DB-clock-stamped watermarks
      # (DEFAULT NOW()) versus app-clock timestamps raced across NTP skew —
      # the same-second invalidation flake was exactly that. Same-node keeps
      # one clock domain for the jarvis runs; skynet runs are deliberately
      # cross-node (accepted noise; jarvis is the box that matters here).
      nodeSelector:
        kubernetes.io/hostname: jarvis-dev
      containers:
        - name: postgres
          image: postgres:16-alpine
          # 16 test threads roughly double peak connections vs the stock
          # max_connections=100 ceiling. Prometheus shows peak working set
          # across the 8-thread soak was ~116MiB, so 1Gi stays ample even at
          # 300 connections; the limit is deliberately NOT raised.
          args: ["-c", "max_connections=300", "-c", "shared_buffers=256MB"]
          env:
            - { name: POSTGRES_USER, value: registry }
            - { name: POSTGRES_PASSWORD, value: registry }
            - { name: POSTGRES_DB, value: artifact_registry }
          readinessProbe:
            exec: { command: [pg_isready, -U, registry, -d, artifact_registry] }
            periodSeconds: 2
            timeoutSeconds: 2
            failureThreshold: 30
          resources:
            requests: { cpu: "1", memory: 256Mi }
            limits: { memory: 1Gi }
---
apiVersion: v1
kind: Service
metadata:
  name: ${name}
spec:
  selector: { app: ${name} }
  ports:
    - { name: postgres, port: 5432, targetPort: 5432 }
YAML

kubectl -n "${namespace}" rollout status "deployment/${name}" --timeout=120s

# Only coverage mode uses COVERAGE_BASE (the new-code diff gate); computing
# it needs history the integration job's checkout deliberately doesn't fetch
# (plain shallow checkout, no fetch-depth: 0). Skip it outside coverage mode
# so integration runs can't fail on an unrelated, unused git lookup.
coverage_base="${COVERAGE_BASE:-}"
if [[ "${mode}" == "coverage" && -z "${coverage_base}" ]]; then
  coverage_base="$(git -C "${root}" merge-base main HEAD 2>/dev/null \
    || git -C "${root}" merge-base origin/main HEAD 2>/dev/null \
    || git -C "${root}" rev-parse HEAD^ 2>/dev/null \
    || true)"
fi

build_args=(
  --progress plain
  --file "${root}/ci/local-ci/Dockerfile.runner"
  --target "${mode}-results"
  --no-cache-filter "${mode}"
  --build-arg "DATABASE_URL=postgresql://registry:registry@${name}.${namespace}.svc.cluster.local:5432/artifact_registry"
  --build-arg "COVERAGE_BASE=${coverage_base}"
  --build-arg "NEW_CODE_MIN=${NEW_CODE_MIN:-70}"
  --build-arg "TOTAL_MIN=${TOTAL_MIN:-50}"
  --build-arg "COVERAGE_TEST_THREADS=${COVERAGE_TEST_THREADS:-8}"
)
if [[ "${mode}" == "integration" ]]; then
  build_args+=(--build-arg "TEST=${test_target}")
fi

echo "==> ${mode} on BuildKit (diff base ${coverage_base})"
docker buildx build \
  "${build_args[@]}" \
  --output "type=local,dest=${results_dir}" \
  "${root}"

echo "==> quality artifacts"
ls -lh "${results_dir}"
