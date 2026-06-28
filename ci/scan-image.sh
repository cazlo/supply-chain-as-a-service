#!/usr/bin/env bash
set -euo pipefail

# Vulnerability-scan a published image by immutable digest and gate on severity.
# Harbor's built-in Trivy is disabled, so scanning happens here in CI. Reads the
# build record written by ci/build-images.sh, runs Trivy against the registry by
# digest (never a mutable tag), writes the JSON report next to the record, and
# exits non-zero when findings meet the configured severity gate.
#
# Trivy runs as a pinned container so the runner needs no host install. The
# scanner image is overridable so it can be sourced from a local mirror instead
# of Docker Hub.
#
# Usage:
#   ci/scan-image.sh <build-record.json> [more-records.json ...]
#
# Environment:
#   HARBOR_REGISTRY, HARBOR_USERNAME, HARBOR_PASSWORD  registry auth (required)
#   TRIVY_SEVERITY     comma list that fails the gate (default HIGH,CRITICAL)
#   TRIVY_EXIT_CODE    exit code when the gate matches (default 1; set 0 to warn)
#   TRIVY_IMAGE        scanner image (default pinned aquasec/trivy by digest)
#   TRIVY_IGNORE_UNFIXED  set to 1 to ignore vulns with no upstream fix

readonly username="${HARBOR_USERNAME:?HARBOR_USERNAME is required}"
readonly password="${HARBOR_PASSWORD:?HARBOR_PASSWORD is required}"
readonly severity="${TRIVY_SEVERITY:-HIGH,CRITICAL}"
readonly gate_exit="${TRIVY_EXIT_CODE:-1}"
# Pinned by digest; tag kept in the ref for human readability only.
readonly trivy_image="${TRIVY_IMAGE:-aquasec/trivy:0.58.1@sha256:ab70a02200597efa04748f210f793936eb647cbcdb0ea69cc30b226d6f5a22c7}"

(( $# >= 1 )) || { echo "usage: ci/scan-image.sh <build-record.json> ..." >&2; exit 2; }

scan_one() {
  local record="$1" image digest report_dir component
  [[ -f "${record}" ]] || { echo "no such record: ${record}" >&2; return 2; }
  image="$(jq -er '.image' "${record}")"
  digest="$(jq -er '.digest' "${record}")"
  component="$(jq -er '.component' "${record}")"
  report_dir="$(dirname "${record}")"
  local target="${image}@${digest}"
  local report="${report_dir}/${component}-trivy.json"

  echo "Scanning ${target} (gate: ${severity})"
  local ignore_unfixed=()
  [[ "${TRIVY_IGNORE_UNFIXED:-0}" == "1" ]] && ignore_unfixed=(--ignore-unfixed)

  # Two passes: a always-zero JSON report for the build record, then the gate.
  docker run --rm \
    -e "TRIVY_USERNAME=${username}" \
    -e "TRIVY_PASSWORD=${password}" \
    "${trivy_image}" image \
      --quiet --format json --severity "${severity}" \
      "${ignore_unfixed[@]}" "${target}" >"${report}"
  echo "Wrote ${report}"

  local found
  found="$(jq '[.Results[]?.Vulnerabilities // [] | length] | add // 0' "${report}")"
  echo "${component}: ${found} ${severity} finding(s)"
  if (( found > 0 )); then
    jq -r '.Results[]? | .Vulnerabilities // [] | .[] |
      "  \(.Severity)\t\(.VulnerabilityID)\t\(.PkgName) \(.InstalledVersion)"' \
      "${report}" | sort -u >&2 || true
    return "${gate_exit}"
  fi
}

rc=0
for record in "$@"; do
  scan_one "${record}" || rc=$?
done
exit "${rc}"
