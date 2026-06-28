#!/usr/bin/env bash
set -euo pipefail

readonly root="$(git rev-parse --show-toplevel)"
readonly metadata="${root}/vendor/upstreams.tsv"

revision_for() {
  awk -F '\t' -v name="$1" '$1 == name { print $5; exit }' "${metadata}"
}

tag_for() {
  awk -F '\t' -v name="$1" '$1 == name { print $6; exit }' "${metadata}"
}

check_backend() {
  local revision tag
  revision="$(revision_for artifact-keeper)"
  tag="$(tag_for artifact-keeper)"
  [[ "${tag}" != "-" ]] || tag="${revision:0:12}"

  docker build --target builder \
    --build-arg "GIT_SHA=${revision}" \
    --build-arg "APP_VERSION=${tag}" \
    --tag "artifact-keeper-backend:source-check-${revision:0:7}" \
    --file "${root}/artifact-keeper/docker/Dockerfile.backend" \
    "${root}/artifact-keeper"
}

check_web() {
  local revision
  revision="$(revision_for artifact-keeper-web)"

  docker build --target build \
    --build-arg "GIT_SHA=${revision}" \
    --build-arg "APP_VERSION=${revision:0:7}" \
    --tag "artifact-keeper-web:source-check-${revision:0:7}" \
    --file "${root}/artifact-keeper-web/Dockerfile" \
    "${root}/artifact-keeper-web"
}

check_chart() {
  local chart="${root}/artifact-keeper-iac/charts/artifact-keeper"
  local values="${chart}/ci/test-values.yaml"

  helm lint "${chart}" --strict --values "${values}"
  helm template artifact-keeper "${chart}" \
    --namespace artifact-keeper \
    --include-crds \
    --values "${values}" |
    kubectl create --dry-run=client --validate=false --filename=- --output=name
}

main() {
  local checks=("${@:-all}")
  local check
  for check in "${checks[@]}"; do
    case "${check}" in
      all)
        check_backend
        check_web
        check_chart
        ;;
      backend) check_backend ;;
      web) check_web ;;
      chart) check_chart ;;
      *)
        echo "usage: $0 [all|backend|web|chart ...]" >&2
        exit 2
        ;;
    esac
  done
}

main "$@"
