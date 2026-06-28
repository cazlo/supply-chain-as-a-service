#!/usr/bin/env bash
set -euo pipefail

# Sign a published image by immutable digest with the lab-controlled cosign key.
# Reads the build record written by ci/build-images.sh and produces a key-based
# cosign signature attached to the image in the registry. Signing is offline:
# the transparency log is disabled because this is a private, key-pair trust root
# rather than keyless/Fulcio. Verify with ci/verify-image.sh against ci/cosign.pub.
#
# cosign is invoked as a native binary (the build runners are daemonless rootless
# act_runners with no Docker daemon). The runner image ships `cosign`; override
# COSIGN_BIN to point elsewhere.
#
# Usage:
#   ci/sign-image.sh <build-record.json> [more-records.json ...]
#
# Environment:
#   HARBOR_USERNAME, HARBOR_PASSWORD  registry auth (required)
#   COSIGN_PRIVATE_KEY  PEM of the lab signing key (required)
#   COSIGN_PASSWORD     passphrase (empty for the unencrypted lab key)
#   COSIGN_BIN          cosign binary (default: cosign on PATH)

readonly username="${HARBOR_USERNAME:?HARBOR_USERNAME is required}"
readonly password="${HARBOR_PASSWORD:?HARBOR_PASSWORD is required}"
: "${COSIGN_PRIVATE_KEY:?COSIGN_PRIVATE_KEY is required}"
# Empty when the key is unencrypted (the lab key is); cosign reads it regardless.
export COSIGN_PASSWORD="${COSIGN_PASSWORD:-}"
readonly cosign_bin="${COSIGN_BIN:-cosign}"

(( $# >= 1 )) || { echo "usage: ci/sign-image.sh <build-record.json> ..." >&2; exit 2; }
command -v "${cosign_bin}" >/dev/null || { echo "cosign not found (set COSIGN_BIN)" >&2; exit 2; }

sign_one() {
  local record="$1" image digest target
  [[ -f "${record}" ]] || { echo "no such record: ${record}" >&2; return 2; }
  image="$(jq -er '.image' "${record}")"
  digest="$(jq -er '.digest' "${record}")"
  target="${image}@${digest}"

  echo "Signing ${target}"
  # The key material and passphrase stay in the environment; never on disk or in
  # the record. Registry auth is passed explicitly (there is no docker config).
  "${cosign_bin}" sign --yes \
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
