#!/usr/bin/env bash
# Upstream-parity backend lint gate (the `Check Rust` job in upstream's
# ci.yml): cargo fmt --check + cargo clippy --workspace --all-targets
# -- -D warnings, via ci/local-ci/Dockerfile.runner's `lint` stage on the
# runner's rootless BuildKit. Unlike ci/backend-quality-k8s.sh this needs no
# ephemeral Postgres: the lint stage compiles with SQLX_OFFLINE=true against
# the committed .sqlx cache, so it is a pure buildx invocation. It shares the
# quality lane's cargo/target cache mounts, so a warm-cache pass is cheap.
set -euo pipefail

readonly root="$(git rev-parse --show-toplevel)"
readonly results_dir="${QUALITY_RESULTS_DIR:-/tmp/artifact-keeper-lint}"

mkdir -p "${results_dir}"

echo "==> lint on BuildKit (fmt --check + clippy -D warnings)"
docker buildx build \
  --progress plain \
  --file "${root}/ci/local-ci/Dockerfile.runner" \
  --target lint-results \
  --no-cache-filter lint \
  --output "type=local,dest=${results_dir}" \
  "${root}"

echo "==> lint artifacts"
ls -lh "${results_dir}"
