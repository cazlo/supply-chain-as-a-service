#!/usr/bin/env bash
set -euo pipefail

# Merge-to-main release promotion for one component. Re-finds the image that was
# pushed to artifact-keeper-staging on the PR — by its reconstructable source key
# (ci/source-key.sh), which survives the merge commit's changed SHA — verifies the
# lab cosign signature, then content-addressed-copies it into
# artifact-keeper-release by digest. No rebuild: the exact bytes that were scanned,
# signed, and smoke-tested on the PR are what ship.
#
# Prints one `<COMPONENT>_RELEASE_IMAGE=<release-repo>@<digest>` line to stdout —
# the value to pin in the Flux deploy (apps/artifact-keeper/release.yaml in the
# GitOps repo) as `tag: <srckey>@<digest>`.
#
# Fails loudly if the staged tag is missing or its signature does not verify:
# there is nothing safe to release, so the run should go red.
#
# Usage: ci/promote-to-release.sh <backend|web>
#
# Environment:
#   HARBOR_REGISTRY   registry host (required)
#   HARBOR_USERNAME, HARBOR_PASSWORD  registry auth (required)
#   COSIGN_BIN, COSIGN_PUBLIC_KEY     optional overrides

readonly root="$(git rev-parse --show-toplevel)"
component="${1:?usage: promote-to-release.sh <backend|web>}"
case "${component}" in
  backend | web) ;;
  *)
    echo "unknown component: ${component}" >&2
    exit 2
    ;;
esac

: "${HARBOR_REGISTRY:?HARBOR_REGISTRY is required}"
: "${HARBOR_USERNAME:?HARBOR_USERNAME is required}"
: "${HARBOR_PASSWORD:?HARBOR_PASSWORD is required}"
readonly cosign_bin="${COSIGN_BIN:-cosign}"
readonly pubkey="${COSIGN_PUBLIC_KEY:-${root}/ci/cosign.pub}"
command -v "${cosign_bin}" >/dev/null || {
  echo "cosign not found (set COSIGN_BIN)" >&2
  exit 2
}
[[ -f "${pubkey}" ]] || {
  echo "missing public key: ${pubkey}" >&2
  exit 2
}

srckey="$("${root}/ci/source-key.sh" "${component}")"
readonly srckey
readonly staging_repo="${HARBOR_REGISTRY}/artifact-keeper-staging/artifact-keeper-${component}"
readonly release_repo="${HARBOR_REGISTRY}/artifact-keeper-release/artifact-keeper-${component}"

# Verify the lab signature on the staged tag AND capture the digest it resolves to
# in one shot: cosign verify emits the SimpleSigning payload on stdout, whose
# docker-manifest-digest is authoritative for the by-digest copy below. A missing
# tag or bad signature makes verify exit non-zero -> set -e aborts the run.
echo "Resolving + verifying ${staging_repo}:${srckey}" >&2
verify_out="$("${cosign_bin}" verify \
  --insecure-ignore-tlog=true \
  --registry-username "${HARBOR_USERNAME}" \
  --registry-password "${HARBOR_PASSWORD}" \
  --key "${pubkey}" \
  "${staging_repo}:${srckey}" 2>/dev/null)"
digest="$(jq -r '.[0].critical.image["docker-manifest-digest"] // empty' <<<"${verify_out}")"
[[ "${digest}" == sha256:* ]] || {
  echo "could not resolve a verified digest for ${staging_repo}:${srckey}" >&2
  exit 1
}
echo "OK ${staging_repo}:${srckey} -> ${digest}" >&2

"${root}/ci/promote-image.sh" "${staging_repo}@${digest}" "${release_repo}" "${srckey}" >&2

printf '%s_RELEASE_IMAGE=%s@%s\n' "${component^^}" "${release_repo}" "${digest}"
