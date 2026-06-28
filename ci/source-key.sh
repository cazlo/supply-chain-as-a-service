#!/usr/bin/env bash
set -euo pipefail

# Print the reconstructable "source key" tag for a component:
#
#   v<version>-src.<srcShort>
#
# It is derived ONLY from committed state (vendor/upstreams.tsv plus the web
# package.json) — deliberately NOT from the monorepo HEAD. The build tag written
# by ci/build-images.sh also carries `local.<monorepoHEAD>`, which changes when
# Gitea creates the merge commit; the source key does not. That makes it the
# stable hand-off between the per-PR staging promotion and the merge-to-main
# release promotion: the value computed on a PR head and on the post-merge commit
# is identical, so release promotion can re-find the staged image by tag without
# rebuilding.
#
# Caveat: a monorepo-only change (Dockerfile/chart edit with no vendored-revision
# bump) reuses the same source key, so the newest staged build wins under it.
# Acceptable for the lab; the stronger form would correlate via the build-record
# artifact. See the supply-chain-lab plan (milestone 7).
#
# This intentionally mirrors ci/build-images.sh's version/revision logic; keep the
# two in sync.
#
# Usage: ci/source-key.sh <backend|web>

readonly root="$(git rev-parse --show-toplevel)"
readonly metadata="${root}/vendor/upstreams.tsv"

component="${1:?usage: source-key.sh <backend|web>}"
case "${component}" in
  backend) upstream_name="artifact-keeper" ;;
  web) upstream_name="artifact-keeper-web" ;;
  *)
    echo "unknown component: ${component}" >&2
    exit 2
    ;;
esac

revision_for() { awk -F '\t' -v name="$1" '$1 == name { print $5; exit }' "${metadata}"; }
tag_for() { awk -F '\t' -v name="$1" '$1 == name { print $6; exit }' "${metadata}"; }

image_version() {
  local name="$1" tag
  tag="$(tag_for "${name}")"
  if [[ "${tag}" != "-" ]]; then
    printf '%s\n' "${tag#v}"
  elif [[ "${name}" == "artifact-keeper-web" ]]; then
    jq -r '.version' "${root}/artifact-keeper-web/package.json"
  else
    revision_for "${name}"
  fi
}

src="$(revision_for "${upstream_name}")"
ver="$(image_version "${upstream_name}")"
printf 'v%s-src.%s\n' "${ver}" "${src:0:8}"
