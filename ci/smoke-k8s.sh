#!/usr/bin/env bash
set -euo pipefail

# K8s-native Artifact Keeper smoke suite (pypi, npm, cargo native clients).
#
# Replaces the rootless-hostile docker-compose smoke path: it helm-installs the
# vendored chart with its CI values into an ephemeral namespace (backend +
# postgres come up as real pods, which also exercises the chart), bootstraps the
# test repositories, runs the vendored native client scripts as Jobs over cluster
# HTTP, then deletes the namespace. The vendored chart and test scripts are used
# unmodified; the scripts are shipped into the Jobs as a gzipped ConfigMap that
# mirrors the compose /scripts, /assets, and /setup.sh mounts.
#
# Requirements: kubectl + helm pointed at a cluster, and the freshly built
# backend image reachable by the cluster (locally: preloaded into the node;
# in CI: a per-PR tag in the Harbor artifact-keeper-ci scratch repo).
#
# Inputs (env):
#   BACKEND_IMAGE_REPO  backend image repository (default: vendored upstream ref)
#   BACKEND_IMAGE_TAG   backend image tag        (default: pinned short revision)
#   NAMESPACE           ephemeral namespace      (default: ak-smoke-<rev>)
#   HARBOR_REGISTRY / HARBOR_USERNAME / HARBOR_PASSWORD
#                       if set, create an image pull secret for the backend image
#   KEEP_NAMESPACE      set to keep the namespace after the run (debugging)

readonly root="$(git rev-parse --show-toplevel)"
readonly chart="${root}/artifact-keeper-iac/charts/artifact-keeper"
readonly values="${chart}/ci/test-values.yaml"
readonly metadata="${root}/vendor/upstreams.tsv"

readonly release="artifact-keeper" # fullnameOverride keeps Service names stable
readonly admin_user="admin"
# Must match backend.env.ADMIN_PASSWORD in ci/test-values.yaml, otherwise the
# backend keeps /readyz locked and helm --wait times out.
readonly admin_pass="CI-test-password-not-for-prod"

revision="$(awk -F '\t' '$1 == "artifact-keeper" { print $5; exit }' "${metadata}")"
readonly backend_repo="${BACKEND_IMAGE_REPO:-ghcr.io/artifact-keeper/artifact-keeper-backend}"
readonly backend_tag="${BACKEND_IMAGE_TAG:-${revision:0:7}}"
readonly ns="${NAMESPACE:-ak-smoke-${revision:0:7}}"
readonly backend_url="http://${release}-backend:8080"

workdir=""
cleanup() {
  [[ -n "${workdir}" ]] && rm -rf "${workdir}"
  [[ -n "${KEEP_NAMESPACE:-}" ]] && return
  kubectl delete namespace "${ns}" --wait=false --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Bundle the vendored test scripts and assets so they land at /scripts, /assets,
# and /setup.sh inside the Jobs, exactly as the compose file mounts them.
build_bundle() {
  workdir="$(mktemp -d)"
  local stage="${workdir}/stage"
  mkdir -p "${stage}/scripts"
  cp -a "${root}/artifact-keeper/scripts/native-tests/." "${stage}/scripts/"
  cp -a "${root}/artifact-keeper/.assets" "${stage}/assets"
  cp "${root}/artifact-keeper/scripts/e2e-setup.sh" "${stage}/setup.sh"
  tar czf "${workdir}/bundle.tgz" -C "${stage}" scripts assets setup.sh
}

# Create a Job that unpacks the bundle and runs a command, then wait for it to
# succeed or fail (backoffLimit 0, so one pod failure is terminal).
run_job() {
  local name="$1" image="$2" prep="$3" cmd="$4"
  kubectl -n "${ns}" apply -f - >/dev/null <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: ${name}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: ${name}
          image: ${image}
          env:
            - { name: REGISTRY_URL, value: "${backend_url}" }
            - { name: ADMIN_USER, value: "${admin_user}" }
            - { name: ADMIN_PASS, value: "${admin_pass}" }
          command: ["sh", "-c"]
          args:
            - |
              set -e
              tar xzf /bundle/bundle.tgz -C /
              ${prep}
              ${cmd}
          volumeMounts:
            - { name: bundle, mountPath: /bundle, readOnly: true }
      volumes:
        - name: bundle
          configMap:
            name: test-bundle
YAML

  local waited=0
  while (( waited < 300 )); do
    if [[ "$(kubectl -n "${ns}" get job "${name}" -o jsonpath='{.status.succeeded}' 2>/dev/null)" == "1" ]]; then
      return 0
    fi
    if [[ "$(kubectl -n "${ns}" get job "${name}" -o jsonpath='{.status.failed}' 2>/dev/null)" =~ ^[1-9] ]]; then
      kubectl -n "${ns}" logs "job/${name}" --tail=40 2>/dev/null || true
      return 1
    fi
    sleep 3
    waited=$(( waited + 3 ))
  done
  echo "timed out waiting for job/${name}" >&2
  return 1
}

main() {
  local tests=("$@")
  [[ ${#tests[@]} -gt 0 ]] || tests=(pypi npm cargo)

  build_bundle

  kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f -

  if [[ -n "${HARBOR_REGISTRY:-}" ]]; then
    kubectl -n "${ns}" create secret docker-registry harbor \
      --docker-server="${HARBOR_REGISTRY}" \
      --docker-username="${HARBOR_USERNAME}" \
      --docker-password="${HARBOR_PASSWORD}" >/dev/null
    kubectl -n "${ns}" patch serviceaccount default \
      -p '{"imagePullSecrets":[{"name":"harbor"}]}' >/dev/null
  fi

  kubectl -n "${ns}" create configmap test-bundle \
    --from-file=bundle.tgz="${workdir}/bundle.tgz" >/dev/null

  # Backend + postgres only; web is not on the package-manager data path.
  helm install "${release}" "${chart}" --namespace "${ns}" \
    --values "${values}" \
    --set fullnameOverride="${release}" \
    --set web.enabled=false \
    --set backend.image.repository="${backend_repo}" \
    --set backend.image.tag="${backend_tag}" \
    --set backend.image.pullPolicy=IfNotPresent \
    --wait --timeout 5m

  # Bootstrap the test repositories before any client runs.
  run_job setup "alpine:3.19" \
    "apk add --no-cache curl jq >/dev/null 2>&1" \
    "sh /setup.sh"

  local status=0 t rc
  for t in "${tests[@]}"; do
    rc=0
    case "${t}" in
      pypi)  run_job pypi-test  "python:3.12-slim" "" "bash /scripts/test-pypi.sh"  || rc=1 ;;
      npm)   run_job npm-test   "node:20-slim"     "" "bash /scripts/test-npm.sh"   || rc=1 ;;
      cargo) run_job cargo-test "rust:1.75-slim"   "" "bash /scripts/test-cargo.sh" || rc=1 ;;
      *) echo "unknown test: ${t}" >&2; rc=1 ;;
    esac
    if [[ "${rc}" -eq 0 ]]; then echo "PASS ${t}"; else echo "FAIL ${t}"; status=1; fi
  done

  return "${status}"
}

main "$@"
