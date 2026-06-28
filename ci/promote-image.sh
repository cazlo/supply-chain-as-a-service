#!/usr/bin/env bash
set -euo pipefail

# Promote an already-published, signed image to another Harbor project by
# content-addressed copy. `cosign copy` moves the manifest AND its attached
# cosign signature / SBOM / provenance, and because the copy is by-digest the
# destination digest is identical to the source — so a `repo:tag@sha256:` pin and
# `cosign verify --key ci/cosign.pub` both still hold in the destination with no
# re-sign. This is how an image earns its way from the CI scratch project into
# `artifact-keeper-staging` (per green PR) and `artifact-keeper-release` (on merge
# to main) without ever rebuilding the bytes that were scanned, signed, and
# smoke-tested.
#
# The build runners are daemonless (rootless act_runner, no Docker daemon and no
# docker config), so we authenticate cosign explicitly with `cosign login`, which
# writes an ephemeral credential under $HOME for the duration of the job.
#
# The source ref MUST be pinned by digest: promotion copies an exact, verified
# artifact, never "whatever a mutable tag points at right now".
#
# Usage:
#   ci/promote-image.sh <src-repo@sha256:...> <dst-repo> <tag> [<tag> ...]
#
# Example:
#   ci/promote-image.sh \
#     oci.cazlab.link/artifact-keeper-ci/artifact-keeper-backend@sha256:44c3... \
#     oci.cazlab.link/artifact-keeper-staging/artifact-keeper-backend \
#     v1.2.1-local.a2ae8102-src.ea6f5ed6 v1.2.1-src.ea6f5ed6
#
# Environment:
#   HARBOR_USERNAME, HARBOR_PASSWORD  registry auth (required)
#   HARBOR_REGISTRY  registry host for login (default: host of <src-repo>)
#   COSIGN_BIN       cosign binary (default: cosign on PATH)

src="${1:?usage: promote-image.sh <src@sha256:...> <dst-repo> <tag> [tag...]}"
dst_repo="${2:?destination repo required}"
shift 2 || true
(($# >= 1)) || {
  echo "at least one destination tag required" >&2
  exit 2
}

: "${HARBOR_USERNAME:?HARBOR_USERNAME is required}"
: "${HARBOR_PASSWORD:?HARBOR_PASSWORD is required}"
readonly cosign_bin="${COSIGN_BIN:-cosign}"
command -v "${cosign_bin}" >/dev/null || {
  echo "cosign not found (set COSIGN_BIN)" >&2
  exit 2
}

[[ "${src}" == *@sha256:* ]] || {
  echo "refusing to promote a non-digest source ref: ${src}" >&2
  exit 2
}

readonly registry="${HARBOR_REGISTRY:-${src%%/*}}"
printf '%s' "${HARBOR_PASSWORD}" |
  "${cosign_bin}" login "${registry}" --username "${HARBOR_USERNAME}" --password-stdin

for tag in "$@"; do
  echo "Promoting ${src} -> ${dst_repo}:${tag}"
  # --force overwrites an existing destination tag (re-promotion is idempotent);
  # by default cosign copies the image plus its signatures and attestations.
  "${cosign_bin}" copy --force "${src}" "${dst_repo}:${tag}"
  echo "Promoted ${dst_repo}:${tag}"
done
