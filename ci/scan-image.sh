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
# The report captures HIGH+CRITICAL for full visibility, but the build gate is
# deliberately narrower: by default only CRITICAL vulns that have an available
# fix fail the build. The vendored upstream images carry base-image CVEs we do
# not own; gating on every unfixable HIGH would keep the publish lane permanently
# red. Tighten with TRIVY_GATE_SEVERITY / TRIVY_GATE_IGNORE_UNFIXED.
#
# Usage:
#   ci/scan-image.sh <build-record.json> [more-records.json ...]
#
# Environment:
#   HARBOR_USERNAME, HARBOR_PASSWORD  registry auth (required)
#   TRIVY_BIN              trivy binary (default: trivy on PATH)
#   TRIVY_REPORT_SEVERITY  severities recorded in the report (default HIGH,CRITICAL)
#   TRIVY_GATE_SEVERITY    severities that fail the build (default CRITICAL)
#   TRIVY_GATE_IGNORE_UNFIXED  1 = only fixed vulns gate (default 1)
#   TRIVY_EXIT_CODE        exit code when the gate matches (default 1; 0 = warn)

readonly username="${HARBOR_USERNAME:?HARBOR_USERNAME is required}"
readonly password="${HARBOR_PASSWORD:?HARBOR_PASSWORD is required}"
readonly trivy_bin="${TRIVY_BIN:-trivy}"
readonly report_severity="${TRIVY_REPORT_SEVERITY:-HIGH,CRITICAL}"
readonly gate_severity="${TRIVY_GATE_SEVERITY:-CRITICAL}"
readonly gate_ignore_unfixed="${TRIVY_GATE_IGNORE_UNFIXED:-1}"
readonly gate_exit="${TRIVY_EXIT_CODE:-1}"
# JSON array of gate severities for jq, e.g. ["CRITICAL"].
gate_sev_json="$(printf '%s' "${gate_severity}" | jq -Rc 'split(",")')"

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

  echo "Scanning ${target} (report: ${report_severity}; gate: ${gate_severity}, ignore-unfixed=${gate_ignore_unfixed})"

  # One scan, full report for the build record.
  TRIVY_USERNAME="${username}" TRIVY_PASSWORD="${password}" \
    "${trivy_bin}" image \
      --quiet --format json --severity "${report_severity}" \
      "${target}" >"${report}"
  echo "Wrote ${report}"

  # Gate count: only the gate severities, and (by default) only fixed vulns.
  local total gate_count
  total="$(jq '[.Results[]?.Vulnerabilities // [] | length] | add // 0' "${report}")"
  gate_count="$(jq --argjson sev "${gate_sev_json}" --argjson unfixed "${gate_ignore_unfixed}" '
    [ .Results[]?.Vulnerabilities // [] | .[]
      | select(.Severity as $s | $sev | index($s))
      | select(($unfixed == 0) or ((.FixedVersion // "") != "")) ]
    | length' "${report}")"
  echo "${component}: ${total} ${report_severity} finding(s); ${gate_count} gating"
  if (( gate_count > 0 )); then
    jq -r --argjson sev "${gate_sev_json}" --argjson unfixed "${gate_ignore_unfixed}" '
      .Results[]?.Vulnerabilities // [] | .[]
      | select(.Severity as $s | $sev | index($s))
      | select(($unfixed == 0) or ((.FixedVersion // "") != ""))
      | "  \(.Severity)\t\(.VulnerabilityID)\t\(.PkgName) \(.InstalledVersion) -> \(.FixedVersion)"' \
      "${report}" | sort -u >&2 || true
    return "${gate_exit}"
  fi
}

rc=0
for record in "$@"; do
  scan_one "${record}" || rc=$?
done
exit "${rc}"
