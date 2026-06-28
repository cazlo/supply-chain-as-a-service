#!/usr/bin/env bash
set -euo pipefail

# Verify the lab cosign signature on an image before it is trusted for smoke or
# deploy. This is the verify-before-deploy gate: the public key ci/cosign.pub is
# committed, so verification needs no secret and can run anywhere (CI smoke, a
# future admission check, or by hand). Transparency-log lookup is disabled to
# match the offline key-based signing in ci/sign-image.sh.
#
# Accepts either a build record (image+digest are read from it) or an explicit
# image reference. Always pin to a digest in real use; a mutable tag is accepted
# only for ad-hoc checks.
#
# Usage:
#   ci/verify-image.sh --record <build-record.json> [...]
#   ci/verify-image.sh <registry/repo@sha256:...> [...]
#
# Environment:
#   COSIGN_PUBLIC_KEY  path to the public key (default ci/cosign.pub)
#   HARBOR_USERNAME, HARBOR_PASSWORD  registry auth (required for private repos)
#   COSIGN_IMAGE       cosign image (default pinned ghcr.io/sigstore/cosign)

readonly root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
readonly pubkey="${COSIGN_PUBLIC_KEY:-${root}/ci/cosign.pub}"
readonly cosign_image="${COSIGN_IMAGE:-ghcr.io/sigstore/cosign:v2.4.1}"

[[ -f "${pubkey}" ]] || { echo "missing public key: ${pubkey}" >&2; exit 2; }
(( $# >= 1 )) || { echo "usage: ci/verify-image.sh [--record <json>|<image@digest>] ..." >&2; exit 2; }

targets=()
if [[ "${1:-}" == "--record" ]]; then
  shift
  (( $# >= 1 )) || { echo "--record needs a file" >&2; exit 2; }
  for record in "$@"; do
    [[ -f "${record}" ]] || { echo "no such record: ${record}" >&2; exit 2; }
    targets+=("$(jq -er '.image + "@" + .digest' "${record}")")
  done
else
  targets=("$@")
fi

auth=()
if [[ -n "${HARBOR_USERNAME:-}" && -n "${HARBOR_PASSWORD:-}" ]]; then
  auth=(--registry-username "${HARBOR_USERNAME}" --registry-password "${HARBOR_PASSWORD}")
fi

for target in "${targets[@]}"; do
  echo "Verifying ${target}"
  docker run --rm \
    -v "${pubkey}:/cosign.pub:ro" \
    "${cosign_image}" verify \
      --insecure-ignore-tlog=true \
      "${auth[@]}" \
      --key /cosign.pub \
      "${target}" >/dev/null
  echo "OK ${target}"
done
