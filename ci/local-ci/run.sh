#!/usr/bin/env bash
# Entry point inside the local-ci container. Mirrors upstream
# artifact-keeper/.github/workflows/ci.yml:
#
#   test        -> the `test-backend-unit` job
#                    sqlx migrate run + cargo test --workspace --lib (DB-backed)
#   coverage    -> the `coverage` job
#                    cargo llvm-cov nextest --workspace --lib, the >=50% overall
#                    floor, and the >=70% new-code (diff) gate the reviewer runs.
#   integration -> the DB-backed `tests/` suites that --lib does NOT build
#                    (default: the age-gate suite). Upstream runs these in its
#                    nightly/e2e lanes; we surface them here so our own
#                    integration tests (patches/0003) actually execute.
#                    Override the target with TEST=<name> (e.g. TEST=oci_...).
#
# Run via the repo-root Makefile: `make local-test` / `make local-coverage` /
# `make local-integration`.
set -euo pipefail

# cargo rewrites Cargo.lock's workspace version field during the build (the
# committed snapshot's lock is one bump behind its Cargo.toml; the production
# Dockerfile seds the version and regenerates the lock in-container too). The
# repo is bind-mounted, so restore the lock on exit to keep the host tree clean.
restore_lock() { git -C /work checkout -- artifact-keeper/Cargo.lock 2>/dev/null || true; }
trap restore_lock EXIT

MODE="${1:-coverage}"
cd /work/artifact-keeper

echo "==> applying migrations (sqlx migrate run)"
sqlx migrate run --source backend/migrations

if [ "${MODE}" = "test" ]; then
  echo "==> cargo test --workspace --lib"
  # --test-threads=1 mirrors upstream: the DB-backed lib tests share tables.
  cargo test --workspace --lib -- --test-threads=1
  exit $?
fi

if [ "${MODE}" = "integration" ]; then
  TEST_TARGET="${TEST:-age_gate_tests}"
  echo "==> cargo test --test ${TEST_TARGET} -- --ignored"
  cargo test --test "${TEST_TARGET}" -- --ignored --test-threads=1
  exit $?
fi

echo "==> cargo llvm-cov nextest --workspace --lib"
cargo llvm-cov nextest --workspace --lib --lcov --output-path /tmp/lcov.info --test-threads 4

echo
echo "==> overall coverage summary"
cargo llvm-cov --workspace --lib --no-run --summary-only

echo
echo "==> overall floor: lines >= ${TOTAL_MIN:-50}%"
cargo llvm-cov --workspace --lib --no-run --fail-under-lines "${TOTAL_MIN:-50}"

echo
echo "==> new-code coverage gate: changed backend/src lines >= ${NEW_CODE_MIN:-70}%"
BASE="${COVERAGE_BASE:-}"
if [ -z "${BASE}" ]; then
  # Default: the merge-base with main == exactly the age-gate patch set, so the
  # gate reports coverage of the work we are trying to land upstream.
  BASE="$(git -C /work merge-base main HEAD 2>/dev/null || git -C /work rev-parse main 2>/dev/null || true)"
fi
if [ -z "${BASE}" ]; then
  echo "   no base ref found; set COVERAGE_BASE=<ref> to enable the new-code gate"
  exit 0
fi
echo "   diffing changed lines against: ${BASE}"
MERGE_BASE="${BASE}" LCOV=/tmp/lcov.info NEW_CODE_MIN="${NEW_CODE_MIN:-70}" \
  python3 /work/ci/local-ci/diff-coverage.py
