#!/usr/bin/env bash
set -euo pipefail

# K8s-native Playwright web E2E lane.
#
# Installs an isolated, uniquely named full-stack release (postgres + backend +
# web, heavy optional services disabled) of the vendored chart in the shared
# ak-smoke namespace, then drives the web UI with a Playwright Kubernetes Job
# built from the vendored test source (ci/web-e2e-image-build.sh). The runners
# are daemonless, so upstream's docker-compose Playwright topology cannot run
# here; the cluster is the only execution substrate.
#
# Unlike ci/smoke-k8s.sh this never uses the fixed `artifact-keeper` release
# name and never sweeps namespace-wide: the namespace is shared with the
# backend smoke and the backend-integration matrix legs, so every resource this
# script creates carries the per-run release name and cleanup is scoped to
# exactly that name (plus the chart's app.kubernetes.io/instance label for the
# statefulset-template PVCs helm uninstall leaves behind). The shared `harbor`
# pull secret is upserted with apply -- never deleted -- for the same reason
# (see ci/backend-integration-run-k8s.sh).
#
# First increment runs only the peers interactions spec with one Chromium
# worker (the #515 lane); broaden via E2E_SPEC/E2E_PROJECT once runtime and
# flake data exist.
#
# Inputs (env):
#   E2E_RUNNER_IMAGE    Playwright runner image (stdout of web-e2e-image-build.sh)
#   BACKEND_IMAGE_REPO / BACKEND_IMAGE_TAG   staged backend image
#   WEB_IMAGE_REPO     / WEB_IMAGE_TAG       staged web image
#   E2E_SPEC            spec path(s) passed to `playwright test` (default: peers)
#   E2E_PROJECT         Playwright project (default: interactions)
#   E2E_RESULTS_DIR     where the report archive + logs land (default below)
#   NAMESPACE           target namespace (default: ak-smoke)
#   HARBOR_REGISTRY / HARBOR_USERNAME / HARBOR_PASSWORD
#                       pull-secret material for the private images
#   KEEP_RELEASE        set to keep the release + resources after the run (debug)

readonly root="$(git rev-parse --show-toplevel)"
readonly chart="${root}/artifact-keeper-iac/charts/artifact-keeper"
readonly values="${chart}/ci/test-values.yaml"

readonly runner_image="${E2E_RUNNER_IMAGE:?E2E_RUNNER_IMAGE is required (stdout of ci/web-e2e-image-build.sh)}"
readonly backend_repo="${BACKEND_IMAGE_REPO:?BACKEND_IMAGE_REPO is required}"
readonly backend_tag="${BACKEND_IMAGE_TAG:?BACKEND_IMAGE_TAG is required}"
readonly web_repo="${WEB_IMAGE_REPO:?WEB_IMAGE_REPO is required}"
readonly web_tag="${WEB_IMAGE_TAG:?WEB_IMAGE_TAG is required}"
readonly spec="${E2E_SPEC:-e2e/suites/interactions/integrations/peers.spec.ts}"
readonly project="${E2E_PROJECT:-interactions}"
readonly results_dir="${E2E_RESULTS_DIR:-/tmp/artifact-keeper-web-e2e}"
readonly ns="${NAMESPACE:-ak-smoke}"

# Must match backend.env.ADMIN_PASSWORD in the chart's ci/test-values.yaml
# (see ci/smoke-k8s.sh): the Playwright global setup logs in with it, and the
# backend locks /readyz on a default-password install.
readonly admin_pass="CI-test-password-not-for-prod"

# Per-run DNS-1035 name: never the fixed `artifact-keeper` release, so this
# lane cannot collide with the backend smoke or another attempt of itself.
readonly revision="$(git rev-parse --short=8 HEAD)"
readonly run_suffix="${GITEA_RUN_NUMBER:-${GITHUB_RUN_NUMBER:-0}}"
readonly name="ak-web-e2e-${revision}-${run_suffix}"

# Scoped teardown only: this run's Job, chart release, and the release's PVCs
# (the postgres volumeClaimTemplate PVC survives helm uninstall). Nothing
# namespace-wide, and never the shared `harbor` secret.
cleanup() {
  [[ -n "${KEEP_RELEASE:-}" ]] && return
  kubectl -n "${ns}" delete job "${name}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  helm uninstall "${name}" --namespace "${ns}" --wait --timeout 2m >/dev/null 2>&1 || true
  kubectl -n "${ns}" delete pvc -l "app.kubernetes.io/instance=${name}" \
    --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p "${results_dir}"

kubectl get namespace "${ns}" >/dev/null 2>&1 || kubectl create namespace "${ns}"

# Clear leftovers from a killed earlier attempt of this same run number.
cleanup

if [[ -n "${HARBOR_REGISTRY:-}" ]]; then
  # Upsert (apply, not create): concurrent lanes share this secret name and a
  # delete-then-create pattern could tear it down under a live pull.
  kubectl -n "${ns}" create secret docker-registry harbor \
    --docker-server="${HARBOR_REGISTRY}" \
    --docker-username="${HARBOR_USERNAME}" \
    --docker-password="${HARBOR_PASSWORD}" \
    --dry-run=client -o yaml | kubectl -n "${ns}" apply -f - >/dev/null
  # The vendored chart exposes imagePullSecrets on neither the backend nor the
  # web deployment, and the web pod has no serviceAccount knob at all -- it
  # always runs as the namespace default SA. Patch the default SA with the
  # same content every lane already relies on (idempotent; ci/smoke-k8s.sh
  # applies the identical patch) rather than hand-editing the vendored chart.
  kubectl -n "${ns}" patch serviceaccount default \
    -p '{"imagePullSecrets":[{"name":"harbor"}]}' >/dev/null
fi

# Backend rides the default SA too (chart's own SA cannot carry the pull
# secret without a chart edit) -- same workaround as ci/smoke-k8s.sh.
helm install "${name}" "${chart}" --namespace "${ns}" \
  --values "${values}" \
  --set fullnameOverride="${name}" \
  --set backend.image.repository="${backend_repo}" \
  --set backend.image.tag="${backend_tag}" \
  --set backend.image.pullPolicy=IfNotPresent \
  --set backend.serviceAccount.create=false \
  --set backend.serviceAccount.name=default \
  --set web.image.repository="${web_repo}" \
  --set web.image.tag="${web_tag}" \
  --set web.image.pullPolicy=IfNotPresent \
  --wait --timeout 6m

base_url="http://${name}-web:3000"
echo "==> release ${name} up; running ${project}:${spec} against ${base_url}"

# The Job runs the suite, archives the report, prints a parseable exit-code
# marker, then HOLDS (up to 10 min) so the report can be `kubectl cp`'d out of
# the still-running container -- a completed pod cannot be copied from. The
# hold is released by touching /tmp/e2e-copied, and the container finally
# exits with the real Playwright status so the Job object stays truthful even
# if this script dies mid-copy.
kubectl -n "${ns}" apply -f - <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: ${name}
  labels: { app: ${name}, ak-smoke-suite: web-e2e }
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 1800
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels: { app: ${name} }
    spec:
      restartPolicy: Never
      imagePullSecrets:
        - name: harbor
      containers:
        - name: playwright
          image: ${runner_image}
          workingDir: /work
          env:
            - { name: CI, value: "true" }
            - { name: PLAYWRIGHT_BASE_URL, value: "${base_url}" }
            - { name: ADMIN_PASSWORD, value: "${admin_pass}" }
          command: ["bash", "-c"]
          args:
            - |
              set -u
              rc=0
              npx playwright test --project="${project}" "${spec}" || rc=\$?
              tar czf /tmp/web-e2e-report.tgz playwright-report test-results 2>/dev/null || true
              echo "PLAYWRIGHT_EXIT_CODE=\${rc}"
              elapsed=0
              while [ ! -f /tmp/e2e-copied ] && [ "\${elapsed}" -lt 600 ]; do
                sleep 5
                elapsed=\$(( elapsed + 5 ))
              done
              exit "\${rc}"
          volumeMounts:
            # Chromium crashes under the default 64Mi /dev/shm.
            - { name: shm, mountPath: /dev/shm }
          resources:
            requests: { cpu: "1", memory: 1Gi }
            limits: { memory: 2Gi }
      volumes:
        - name: shm
          emptyDir: { medium: Memory, sizeLimit: 512Mi }
YAML

# Poll for the marker line rather than Job completion: the container is still
# holding for the report copy when the suite finishes. Reads tolerate
# transient NotFound the same way ci/backend-integration-run-k8s.sh does.
rc=""
deadline=$(( $(date +%s) + 1200 ))
while [ "$(date +%s)" -lt "${deadline}" ]; do
  marker="$(kubectl -n "${ns}" logs "job/${name}" --tail=50 2>/dev/null |
    grep -m1 '^PLAYWRIGHT_EXIT_CODE=' || true)"
  if [[ -n "${marker}" ]]; then
    rc="${marker#PLAYWRIGHT_EXIT_CODE=}"
    break
  fi
  job_failed="$(kubectl -n "${ns}" get "job/${name}" -o jsonpath='{.status.failed}' 2>/dev/null || true)"
  if [ "${job_failed:-0}" -ge 1 ] 2>/dev/null; then
    break
  fi
  sleep 5
done

kubectl -n "${ns}" logs "job/${name}" --tail=-1 > "${results_dir}/playwright.log" 2>&1 || true
echo "==> playwright log"
cat "${results_dir}/playwright.log" || true

pod="$(kubectl -n "${ns}" get pods -l "job-name=${name}" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -n "${rc}" && -n "${pod}" ]]; then
  kubectl -n "${ns}" cp "${pod}:/tmp/web-e2e-report.tgz" \
    "${results_dir}/web-e2e-report.tgz" >/dev/null 2>&1 || true
  # Release the hold so the pod exits with the real status immediately.
  kubectl -n "${ns}" exec "${pod}" -- touch /tmp/e2e-copied >/dev/null 2>&1 || true
fi

if [[ "${rc}" != "0" ]]; then
  # Keep the application side of the failure story next to the report.
  kubectl -n "${ns}" logs "deployment/${name}-backend" --tail=400 \
    > "${results_dir}/backend.log" 2>&1 || true
  kubectl -n "${ns}" logs "deployment/${name}-web" --tail=400 \
    > "${results_dir}/web.log" 2>&1 || true
  kubectl -n "${ns}" get pods -l "app.kubernetes.io/instance=${name}" -o wide \
    > "${results_dir}/pods.txt" 2>&1 || true
  kubectl -n "${ns}" describe "job/${name}" \
    > "${results_dir}/job-describe.txt" 2>&1 || true
  if [[ -z "${rc}" ]]; then
    echo "web-e2e job never reported a Playwright exit code (crashed or timed out)" >&2
  else
    echo "web-e2e suite failed (playwright exit code ${rc})" >&2
  fi
  exit 1
fi

echo "PASS web-e2e (${project}:${spec})"
