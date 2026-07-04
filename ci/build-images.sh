#!/usr/bin/env bash
set -euo pipefail

# Build and publish the vendored Artifact Keeper images with deterministic tags,
# registry-backed BuildKit cache, SBOM/provenance attestations, and a compact
# machine-readable build record. The caller owns authentication; credentials are
# accepted only through the environment and are never written to the record.

readonly root="$(git rev-parse --show-toplevel)"
readonly metadata="${root}/vendor/upstreams.tsv"
readonly output_dir="${BUILD_OUTPUT_DIR:-${root}/.artifacts}"
readonly registry="${HARBOR_REGISTRY:?HARBOR_REGISTRY is required}"
readonly project="${HARBOR_PROJECT:-artifact-keeper-ci}"
readonly cache_project="${HARBOR_CACHE_PROJECT:-artifact-keeper-cache}"
readonly local_revision="$(git -C "${root}" rev-parse HEAD)"
readonly local_short="${local_revision:0:8}"
readonly built_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
readonly builder_name="${BUILDX_BUILDER:-default}"
readonly runner_name="${GITEA_RUNNER_NAME:-workstation}"

revision_for() {
  awk -F '\t' -v name="$1" '$1 == name { print $5; exit }' "${metadata}"
}

tag_for() {
  awk -F '\t' -v name="$1" '$1 == name { print $6; exit }' "${metadata}"
}

image_version() {
  local name="$1" tag
  tag="$(tag_for "${name}")"
  if [[ "${tag}" != "-" ]]; then
    printf '%s\n' "${tag#v}"
  elif [[ "${name}" == "artifact-keeper-web" ]]; then
    jq -r '.version' "${root}/artifact-keeper-web/package.json"
  else
    # No release tag recorded (e.g. pinned mid-stream past the last tag to
    # validate an unmerged upstream PR): fall back to a valid semver
    # placeholder instead of the raw revision. Cargo's version parser rejects
    # a bare commit SHA whenever it doesn't start with a digit.
    printf '0.0.0-src.%s\n' "$(revision_for "${name}" | cut -c1-8)"
  fi
}

require_tools() {
  local tool
  for tool in docker git jq sha256sum; do
    command -v "${tool}" >/dev/null || {
      echo "required tool not found: ${tool}" >&2
      exit 2
    }
  done
}

login() {
  [[ -n "${HARBOR_USERNAME:-}" ]] || {
    echo "HARBOR_USERNAME is required" >&2
    exit 2
  }
  [[ -n "${HARBOR_PASSWORD:-}" ]] || {
    echo "HARBOR_PASSWORD is required" >&2
    exit 2
  }
  printf '%s' "${HARBOR_PASSWORD}" |
    docker login "${registry}" --username "${HARBOR_USERNAME}" --password-stdin
}

logout() {
  docker logout "${registry}" >/dev/null 2>&1 || true
}

build_one() {
  local component="$1" upstream_name context dockerfile
  case "${component}" in
    backend)
      upstream_name="artifact-keeper"
      context="${root}/artifact-keeper"
      dockerfile="${context}/docker/Dockerfile.backend"
      ;;
    web)
      upstream_name="artifact-keeper-web"
      context="${root}/artifact-keeper-web"
      dockerfile="${context}/Dockerfile"
      ;;
    *)
      echo "unknown component: ${component}" >&2
      return 2
      ;;
  esac

  local source_revision source_short version image tag cache_ref metadata_file
  source_revision="$(revision_for "${upstream_name}")"
  source_short="${source_revision:0:8}"
  version="$(image_version "${upstream_name}")"
  image="${registry}/${project}/artifact-keeper-${component}"
  tag="v${version}-local.${local_short}-src.${source_short}"
  cache_ref="${registry}/${cache_project}/artifact-keeper-${component}:buildcache"
  metadata_file="${output_dir}/${component}-metadata.json"

  echo "Building ${image}:${tag}"
  docker buildx build \
    --file "${dockerfile}" \
    --build-arg "GIT_SHA=${source_revision}" \
    --build-arg "APP_VERSION=v${version}" \
    --label "org.opencontainers.image.revision=${source_revision}" \
    --label "org.opencontainers.image.version=${version}" \
    --cache-from "type=registry,ref=${cache_ref}" \
    --cache-to "type=registry,ref=${cache_ref},mode=max" \
    --sbom=true \
    --provenance=mode=max \
    --metadata-file "${metadata_file}" \
    --tag "${image}:${tag}" \
    --push \
    "${context}"

  local digest dockerfile_digest dependency_lock dependency_lock_digest
  digest="$(jq -er '."containerimage.digest"' "${metadata_file}")"
  dockerfile_digest="$(sha256sum "${dockerfile}" | awk '{print $1}')"
  if [[ "${component}" == "backend" ]]; then
    dependency_lock="artifact-keeper/Cargo.lock"
  else
    dependency_lock="artifact-keeper-web/package-lock.json"
  fi
  dependency_lock_digest="$(sha256sum "${root}/${dependency_lock}" | awk '{print $1}')"
  jq -n \
    --arg component "${component}" \
    --arg image "${image}" \
    --arg tag "${tag}" \
    --arg digest "${digest}" \
    --arg source_revision "${source_revision}" \
    --arg local_revision "${local_revision}" \
    --arg dockerfile "${dockerfile#${root}/}" \
    --arg dockerfile_digest "sha256:${dockerfile_digest}" \
    --arg dependency_lock "${dependency_lock}" \
    --arg dependency_lock_digest "sha256:${dependency_lock_digest}" \
    --arg cache_ref "${cache_ref}" \
    --arg built_at "${built_at}" \
    --arg builder "${builder_name}" \
    --arg runner "${runner_name}" \
    '{
      component: $component,
      image: $image,
      tag: $tag,
      digest: $digest,
      source_revision: $source_revision,
      local_revision: $local_revision,
      dockerfile: $dockerfile,
      dockerfile_digest: $dockerfile_digest,
      dependency_lock: $dependency_lock,
      dependency_lock_digest: $dependency_lock_digest,
      cache_ref: $cache_ref,
      built_at: $built_at,
      builder: $builder,
      runner: $runner,
      sbom: "buildkit-attestation",
      provenance: "buildkit-mode-max"
    }' >"${output_dir}/${component}-record.json"

  printf '%s=%s\n' "${component^^}_IMAGE" "${image}" >>"${output_dir}/images.env"
  printf '%s=%s\n' "${component^^}_TAG" "${tag}" >>"${output_dir}/images.env"
  printf '%s=%s\n' "${component^^}_DIGEST" "${digest}" >>"${output_dir}/images.env"
  echo "Published ${image}@${digest}"
}

main() {
  require_tools
  mkdir -p "${output_dir}"
  rm -f "${output_dir}"/*-metadata.json "${output_dir}"/*-record.json \
    "${output_dir}/build-record.json"
  : >"${output_dir}/images.env"
  login
  trap logout EXIT

  local components=("$@") component
  [[ ${#components[@]} -gt 0 ]] || components=(backend web)
  for component in "${components[@]}"; do
    build_one "${component}"
  done

  jq -s \
    --arg schema "cazlab.artifact-keeper.build-record/v1" \
    --arg built_at "${built_at}" \
    --arg builder "${builder_name}" \
    --arg runner "${runner_name}" \
    --rawfile upstreams "${metadata}" \
    '{
      schema: $schema,
      built_at: $built_at,
      builder: $builder,
      runner: $runner,
      vendored_sources: (
        $upstreams
        | split("\n")
        | .[1:]
        | map(select(length > 0) | split("\t"))
        | map({name: .[0], revision: .[4], tag: .[5]})
      ),
      images: .
    }' \
    "${output_dir}"/*-record.json >"${output_dir}/build-record.json"
  jq . "${output_dir}/build-record.json"
}

main "$@"
