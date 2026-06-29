#!/usr/bin/env bash
# Run the DB-backed age-gate integration suite and upstream-equivalent coverage
# gates on a daemonless Gitea runner. PostgreSQL lives briefly in the runner's
# RBAC-confined ak-smoke namespace; compilation/tests run in rootless BuildKit.
set -euo pipefail

readonly root="$(git rev-parse --show-toplevel)"
readonly namespace="${QUALITY_NAMESPACE:-ak-smoke}"
readonly revision="$(git -C "${root}" rev-parse --short=8 HEAD)"
readonly run_suffix="${GITEA_RUN_NUMBER:-${GITHUB_RUN_NUMBER:-0}}"
readonly name="ak-quality-${revision}-${run_suffix}"
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
      containers:
        - name: postgres
          image: postgres:16-alpine
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
            requests: { cpu: 250m, memory: 256Mi }
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

coverage_base="${COVERAGE_BASE:-}"
if [[ -z "${coverage_base}" ]]; then
  coverage_base="$(git -C "${root}" merge-base main HEAD 2>/dev/null \
    || git -C "${root}" merge-base origin/main HEAD 2>/dev/null \
    || git -C "${root}" rev-parse HEAD^)"
fi

echo "==> integration + coverage on BuildKit (diff base ${coverage_base})"
docker buildx build \
  --file "${root}/ci/local-ci/Dockerfile.runner" \
  --target results \
  --no-cache-filter gates \
  --build-arg "DATABASE_URL=postgresql://registry:registry@${name}.${namespace}.svc.cluster.local:5432/artifact_registry" \
  --build-arg "COVERAGE_BASE=${coverage_base}" \
  --build-arg "NEW_CODE_MIN=${NEW_CODE_MIN:-70}" \
  --build-arg "TOTAL_MIN=${TOTAL_MIN:-50}" \
  --output "type=local,dest=${results_dir}" \
  "${root}"

echo "==> quality artifacts"
ls -lh "${results_dir}"
