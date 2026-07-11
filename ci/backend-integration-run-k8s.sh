#!/usr/bin/env bash
# Run one backend/tests/*.rs integration-test binary from the pre-built
# artifact-keeper-backend-test-runner image (ci/backend-test-image-build.sh)
# against its own ephemeral Postgres deployment in the daemonless runner's
# RBAC-confined k8s namespace. Unlike ci/backend-quality-k8s.sh, this does
# no compilation of its own -- the image already has every test binary
# under /test-bin, so each matrix leg is just "stand up Postgres, run one
# already-built binary, tear down."
set -euo pipefail

readonly test_target="${TEST:?TEST=<backend/tests/*.rs target> is required}"
readonly image="${TEST_RUNNER_IMAGE:?TEST_RUNNER_IMAGE is required (stdout of backend-test-image-build.sh)}"
readonly harbor_registry="${HARBOR_REGISTRY:?HARBOR_REGISTRY is required to pull ${image}}"
readonly harbor_username="${HARBOR_USERNAME:?HARBOR_USERNAME is required}"
readonly harbor_password="${HARBOR_PASSWORD:?HARBOR_PASSWORD is required}"
readonly namespace="${QUALITY_NAMESPACE:-ak-smoke}"
readonly revision="$(git rev-parse --short=8 HEAD)"
readonly run_suffix="${GITEA_RUN_NUMBER:-${GITHUB_RUN_NUMBER:-0}}"
readonly results_dir="${QUALITY_RESULTS_DIR:-/tmp/artifact-keeper-quality}"

# Deployment/Service/Job name must stay a valid k8s DNS-1035 label. Suffix
# with the sanitized test target so concurrent matrix legs never collide on
# the same resource name in the shared namespace (mirrors
# backend-quality-k8s.sh's naming).
name_suffix="${test_target//_/-}"
name="$(printf '%s' "ak-int-${revision}-${run_suffix}-${name_suffix}" | cut -c1-63)"
readonly name="${name%-}"

cleanup() {
  kubectl -n "${namespace}" delete job,service,deployment "${name}" \
    --ignore-not-found --wait=true >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p "${results_dir}"
rm -f "${results_dir}/integration.log"

# Ensure the Harbor pull secret exists in this namespace so the Job below
# can pull the private artifact-keeper-ci test-runner image (ImagePullBackOff
# otherwise: this namespace has no imagePullSecrets configured by default,
# unlike the production namespace's Flux-managed one). Named "harbor" to
# match ci/smoke-k8s.sh's convention, but applied (not create+delete) so
# concurrent matrix legs upserting the same content never race each other
# into a torn-down state the way a delete-then-create pattern would.
kubectl -n "${namespace}" create secret docker-registry harbor \
  --docker-server="${harbor_registry}" \
  --docker-username="${harbor_username}" \
  --docker-password="${harbor_password}" \
  --dry-run=client -o yaml | kubectl -n "${namespace}" apply -f - >/dev/null

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
          # Probe over TCP (-h 127.0.0.1), not the default unix socket: the
          # postgres image's initdb runs a TEMPORARY socket-only server that
          # pg_isready happily answers, so a socket probe can mark the pod
          # Ready during the init double-start window while the real TCP
          # server is still coming up ("the database system is starting up"
          # seen by the migrate step in runs 525/525-rerun).
          readinessProbe:
            exec: { command: [pg_isready, -h, 127.0.0.1, -U, registry, -d, artifact_registry] }
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

kubectl -n "${namespace}" apply -f - <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: ${name}
  labels: { app: ${name} }
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 480
  # Self-GC for orphaned Jobs (runner killed before its trap cleanup):
  # smoke-k8s.sh's namespace sweep used to catch these, but that sweep is now
  # label-scoped to its own Jobs so it can no longer kill a live leg. 1 h is
  # far beyond the ~3 s completion-poll + log collection below.
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels: { app: ${name} }
    spec:
      restartPolicy: Never
      imagePullSecrets:
        - name: harbor
      containers:
        - name: test
          image: ${image}
          workingDir: /work/artifact-keeper
          command: ["bash", "-o", "pipefail", "-c"]
          args:
            - |
              # Fail the Job rather than run tests against an unmigrated
              # database (pre-fix, a failed migrate fell through and every
              # test died with 42P01 relation-missing). The retry rides out
              # any residual startup window the TCP readiness probe misses.
              set -eu
              for attempt in \$(seq 1 10); do
                if sqlx migrate run --source backend/migrations; then
                  break
                fi
                if [ "\${attempt}" -eq 10 ]; then
                  echo "sqlx migrate run failed after \${attempt} attempts" >&2
                  exit 1
                fi
                echo "migrate attempt \${attempt} failed; retrying" >&2
                sleep 3
              done
              exec "/test-bin/${test_target}" --ignored --test-threads=1
          env:
            - name: DATABASE_URL
              value: "postgresql://registry:registry@${name}.${namespace}.svc.cluster.local:5432/artifact_registry"
YAML

# `kubectl apply` reporting "created" does not guarantee the Job is visible
# to a subsequent, separate `kubectl` call yet -- across this cluster's
# multi-node HA control plane, apply and a following read can land on
# different API servers before etcd replication catches up. A single
# "wait until visible, then kubectl wait --for=condition" split doesn't
# fully close this: the visibility check and the wait are still two
# independent kubectl calls that can each separately land on a lagging
# node (observed: the visibility poll found it, then the very next
# `kubectl wait` call still hit NotFound). Poll status.succeeded/failed
# directly instead -- every read tolerates a transient NotFound the same
# way (empty output, loop continues) rather than needing kubectl wait's
# condition-matching to also be race-tolerant.
deadline=$(( $(date +%s) + 420 ))
while [ "$(date +%s)" -lt "${deadline}" ]; do
  job_succeeded="$(kubectl -n "${namespace}" get "job/${name}" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)"
  job_failed="$(kubectl -n "${namespace}" get "job/${name}" -o jsonpath='{.status.failed}' 2>/dev/null || true)"
  [ "${job_succeeded:-0}" -ge 1 ] 2>/dev/null && break
  [ "${job_failed:-0}" -ge 1 ] 2>/dev/null && break
  sleep 3
done

kubectl -n "${namespace}" logs "job/${name}" --all-containers --prefix > "${results_dir}/integration.log" 2>&1 || true
echo "==> integration log (${test_target})"
cat "${results_dir}/integration.log"

# Read the Job's own succeeded count rather than trusting `kubectl wait`'s
# exit code: `--for=condition=complete` also returns nonzero on a plain
# timeout, which would misreport a still-running (not failed) Job as a test
# failure.
succeeded="$(kubectl -n "${namespace}" get "job/${name}" -o jsonpath='{.status.succeeded}' 2>/dev/null || echo 0)"
if [[ "${succeeded:-0}" -lt 1 ]]; then
  echo "backend-integration job for ${test_target} did not report success (status.succeeded=${succeeded:-0})" >&2
  exit 1
fi
