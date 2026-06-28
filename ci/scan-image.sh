#!/usr/bin/env bash
set -euo pipefail

# Vulnerability-scan a published image by immutable digest and gate on severity.
# Harbor's built-in Trivy is disabled, so scanning happens here in CI. Reads the
# build record written by ci/build-images.sh, runs Trivy against the registry by
# digest (never a mutable tag), writes the JSON report next to the record, and
# exits non-zero when findings meet the configured severity gate.
#
# Trivy is invoked as a native binary (the build runners are daemonless rootless
# act_runners with no Docker daemon, so `docker run` is not available). The
# runner image ships `trivy`; override TRIVY_BIN to point elsewhere.
#
# Usage:
#   ci/scan-image.sh <build-record.json> [more-records.json ...]
#
# Environment:
#   HARBOR_USERNAME, HARBOR_PASSWORD  registry auth (required)
#   TRIVY_BIN          trivy binary (default: trivy on PATH)
#   TRIVY_SEVERITY     comma list that fails the gate (default HIGH,CRITICAL)
#   TRIVY_EXIT_CODE    exit code when the gate matches (default 1; set 0 to warn)
#   TRIVY_IGNORE_UNFIXED  set to 1 to ignore vulns with no upstream fix

readonly username="${HARBOR_USERNAME:?HARBOR_USERNAME is required}"
readonly password="${HARBOR_PASSWORD:?HARBOR_PASSWORD is required}"
readonly trivy_bin="${TRIVY_BIN:-trivy}"
readonly severity="${TRIVY_SEVERITY:-HIGH,CRITICAL}"
readonly gate_exit="${TRIVY_EXIT_CODE:-1}"

(( $# >= 1 )) || { echo "usage: ci/scan-image.sh <build-record.json> ..." >&2; exit 2; }
command -v "${trivy_bin}" >/dev/null || { echo "trivy not found (set TRIVY_BIN)" >&2; exit 2; }

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

  # Write an always-zero JSON report for the build record, then gate on it.
  TRIVY_USERNAME="${username}" TRIVY_PASSWORD="${password}" \
    "${trivy_bin}" image \
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
