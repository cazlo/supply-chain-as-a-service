#!/usr/bin/env bash
set -euo pipefail

# Sign a published image by immutable digest with the lab-controlled cosign key.
# Reads the build record written by ci/build-images.sh and produces a key-based
# cosign signature attached to the image in the registry. Signing is offline:
# the transparency log is disabled because this is a private, key-pair trust root
# rather than keyless/Fulcio. Verify with ci/verify-image.sh against ci/cosign.pub.
#
# cosign runs as a pinned container so the runner needs no host install. The
# cosign image is overridable so it can be sourced from a local mirror.
#
# Usage:
#   ci/sign-image.sh <build-record.json> [more-records.json ...]
#
# Environment:
#   HARBOR_REGISTRY, HARBOR_USERNAME, HARBOR_PASSWORD  registry auth (required)
#   COSIGN_PRIVATE_KEY  PEM of the lab signing key (required)
#   COSIGN_PASSWORD     passphrase for the key (required; may be empty string)
#   COSIGN_IMAGE        cosign image (default pinned ghcr.io/sigstore/cosign)

readonly username="${HARBOR_USERNAME:?HARBOR_USERNAME is required}"
readonly password="${HARBOR_PASSWORD:?HARBOR_PASSWORD is required}"
: "${COSIGN_PRIVATE_KEY:?COSIGN_PRIVATE_KEY is required}"
: "${COSIGN_PASSWORD?COSIGN_PASSWORD is required (export it, empty is allowed)}"
# TODO: pin by digest once ghcr egress/mirroring is available (see scan-image.sh).
readonly cosign_image="${COSIGN_IMAGE:-ghcr.io/sigstore/cosign:v2.4.1}"

(( $# >= 1 )) || { echo "usage: ci/sign-image.sh <build-record.json> ..." >&2; exit 2; }

sign_one() {
  local record="$1" image digest target
  [[ -f "${record}" ]] || { echo "no such record: ${record}" >&2; return 2; }
  image="$(jq -er '.image' "${record}")"
  digest="$(jq -er '.digest' "${record}")"
  target="${image}@${digest}"

  echo "Signing ${target}"
  # cosign authenticates to the registry with these env vars; the key material
  # and passphrase are passed by env and never written to disk or the record.
  docker run --rm \
    -e "COSIGN_PRIVATE_KEY=${COSIGN_PRIVATE_KEY}" \
    -e "COSIGN_PASSWORD=${COSIGN_PASSWORD}" \
    "${cosign_image}" sign --yes \
      --tlog-upload=false \
      --registry-username "${username}" \
      --registry-password "${password}" \
      --key env://COSIGN_PRIVATE_KEY \
      "${target}"
  echo "Signed ${target}"
}

for record in "$@"; do
  sign_one "${record}"
done
