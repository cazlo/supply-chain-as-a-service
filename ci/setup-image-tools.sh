#!/usr/bin/env bash
set -euo pipefail

# Install cosign and trivy into the daemonless build runner if they are not
# already present. The host-mode act_runner has no Docker daemon, so the signing
# and scanning steps use native binaries rather than `docker run`. This is a
# no-op once the binaries are baked into the runner image
# (apps/gitea-runners/runner-image in the GitOps repo).
#
# Versions are pinned; bump deliberately. Binaries land in BIN_DIR (default
# /usr/local/bin, already on PATH and root-writable in the runner container).

readonly bin_dir="${BIN_DIR:-/usr/local/bin}"
readonly cosign_version="${COSIGN_VERSION:-v2.4.1}"
readonly trivy_version="${TRIVY_VERSION:-0.58.1}"
readonly arch="linux-amd64"

if command -v cosign >/dev/null; then
  echo "cosign present: $(cosign version --json 2>/dev/null | grep -o '"gitVersion":"[^"]*"' || cosign version 2>&1 | head -1)"
else
  echo "installing cosign ${cosign_version}"
  curl -fsSLo "${bin_dir}/cosign" \
    "https://github.com/sigstore/cosign/releases/download/${cosign_version}/cosign-${arch}"
  chmod +x "${bin_dir}/cosign"
fi

if command -v trivy >/dev/null; then
  echo "trivy present: $(trivy --version 2>/dev/null | head -1)"
else
  echo "installing trivy ${trivy_version}"
  curl -fsSL \
    "https://github.com/aquasecurity/trivy/releases/download/v${trivy_version}/trivy_${trivy_version}_Linux-64bit.tar.gz" |
    tar -xz -C "${bin_dir}" trivy
  chmod +x "${bin_dir}/trivy"
fi

cosign version 2>&1 | head -1 || true
trivy --version 2>&1 | head -1 || true
