#!/usr/bin/env bash
# Entry point inside the local-ci container. Mirrors upstream
# artifact-keeper/.github/workflows/ci.yml:
#
#   lint        -> the `Check Rust` job
#                    cargo fmt --check + cargo clippy --workspace
#                    --all-targets -- -D warnings, on the committed .sqlx
#                    cache (SQLX_OFFLINE); needs no database.
#   test        -> the `test-backend-unit` job
#                    sqlx migrate run + cargo test --workspace --lib (DB-backed)
#   coverage    -> the `coverage` job
#                    cargo nextest run --workspace --lib under cargo-llvm-cov
#                    instrumentation, the >=50% overall floor, and the >=70%
#                    new-code (diff) gate the reviewer runs.
#   integration -> a DB-backed `tests/` suite that --lib does NOT build.
#                    Upstream runs these in its nightly/e2e lanes; use
#                    TEST=<name> to select a hermetic target.
#
# Run via the repo-root Makefile: `make local-lint` / `make local-test` /
# `make local-coverage` / `make local-integration`.
set -euo pipefail

# cargo rewrites Cargo.lock's workspace version field during the build (the
# committed snapshot's lock is one bump behind its Cargo.toml; the production
# Dockerfile seds the version and regenerates the lock in-container too). The
# repo is bind-mounted, so restore the lock on exit to keep the host tree clean.
restore_lock() { git -C /work checkout -- artifact-keeper/Cargo.lock 2>/dev/null || true; }
trap restore_lock EXIT

MODE="${1:-coverage}"
cd /work/artifact-keeper

# Lint needs no database (SQLX_OFFLINE macro checks ride the committed .sqlx
# cache), so it exits before the migrate step every other mode shares. Added
# after upstream PR #2415's first push failed clippy: the coverage lane runs
# tests but had no fmt/clippy parity, so clippy-only breakage stayed
# invisible until upstream's Check Rust job.
if [ "${MODE}" = "lint" ]; then
  echo "==> cargo fmt --check"
  cargo fmt --check
  echo "==> cargo clippy --workspace --all-targets -- -D warnings"
  cargo clippy --workspace --all-targets -- -D warnings
  exit $?
fi

echo "==> applying migrations (sqlx migrate run)"
sqlx migrate run --source backend/migrations

if [ "${MODE}" = "test" ]; then
  echo "==> cargo test --workspace --lib"
  # --test-threads=1 mirrors upstream: the DB-backed lib tests share tables.
  cargo test --workspace --lib -- --test-threads=1
  exit $?
fi

if [ "${MODE}" = "integration" ]; then
  TEST_TARGET="${TEST:-}"
  if [ -z "${TEST_TARGET}" ]; then
    echo "TEST=<integration-test-target> is required for integration mode" >&2
    exit 2
  fi
  echo "==> cargo test --test ${TEST_TARGET} -- --ignored"
  cargo test --test "${TEST_TARGET}" -- --ignored --test-threads=1
  exit $?
fi

coverage_filter=()
if [ -n "${COVERAGE_NEXTEST_FILTER:-}" ]; then
  coverage_filter=(--filter-expr "${COVERAGE_NEXTEST_FILTER}")
  echo "==> coverage nextest filter: ${COVERAGE_NEXTEST_FILTER}"
fi

# Epoch-stamped phase markers: the tee'd coverage.log is the only per-phase
# timing source (Gitea clips step logs at 2MiB, historically mid-test-phase).
phase() { echo "==> phase ${1} @ $(date +%s)"; }

# Diagnostic slow threshold: nextest's default only flags tests >=60s, hiding
# the 10-60s stragglers the wall-clock plan hunts. Appended at run time (the
# copied build context is writable) so the vendored workspace config stays
# byte-identical to upstream; TOML allows the [profile.default] super-table
# to follow the file's existing [[profile.default.overrides]] entries.
# terminate-after counts periods: 60 x 10s = any single test exceeding 10
# minutes is killed and reported as TIMEOUT instead of wedging the runner
# slot forever (run 357: npm warms-cache test hung 16+ min in an async wait
# with nextest waiting indefinitely - no global timeout otherwise exists).
printf '\n[profile.default]\nslow-timeout = { period = "%s", terminate-after = %s, grace-period = "10s" }\n' \
  "${COVERAGE_SLOW_TIMEOUT:-10s}" "${COVERAGE_SLOW_TERMINATE_AFTER:-60}" >> .config/nextest.toml

# Straggler head-start (wall-clock lever 1): start the measured long-pole
# tests first so their runtime hides under the parallel blast instead of
# padding the tail (LPT scheduling). Tier 100 = the >=28s tests from 16T
# diagnostic runs 299-301 — all sleep-dominated (30s/60s DB-unreachable
# acquire waits), and 7 of the 15 sit in the upstream db-serial group whose
# one-at-a-time chain is ~4 min of wall if it starts late (the group cap
# still applies, so at most ~9 of these hold threads concurrently).
# Tier 50 = the 10-17s band. Later entries never override the earlier
# db-serial test-group assignment (per-key first-match wins in nextest).
cat >> .config/nextest.toml <<'PRIORITIES'

[[profile.default.overrides]]
priority = 100
filter = 'test(=services::permission_service::tests::test_cache_population_then_invalidate_then_miss) | test(=services::storage_gc_service::tests::test_run_blob_gc_returns_error_when_db_unreachable) | test(=services::scan_result_service::tests::test_cleanup_stuck_scans_clamps_overflow_threshold) | test(=services::permission_service::tests::test_check_permission_expired_cache_falls_through_to_db_error) | test(=services::permission_service::tests::test_check_permission_no_cache_entry_falls_through_to_db_error) | test(=services::permission_service::tests::test_has_any_rules_expired_cache_falls_through_to_db_error) | test(=services::permission_service::tests::test_has_any_rules_no_cache_entry_falls_through_to_db_error) | test(=services::permission_service::tests::test_resolve_actions_expired_entry_triggers_db_error) | test(=services::scan_result_service::tests::test_cleanup_stuck_scans_handles_zero_threshold) | test(=api::middleware::guest_access::tests::guard_rejects_request_with_invalid_bearer_when_disabled) | test(=services::storage_gc_service::tests::test_run_blob_gc_dry_run_returns_error_when_db_unreachable) | test(=services::storage_gc_service::tests::test_run_gc_dry_run_returns_error_when_db_unreachable) | test(=services::storage_gc_service::tests::test_run_gc_returns_error_when_db_unreachable) | test(=services::lifecycle_service::tests::test_create_global_type_without_repository_id_passes_repo_guard) | test(=services::scan_result_service::tests::test_cleanup_stuck_scans_returns_database_error_on_connection_failure)'

[[profile.default.overrides]]
priority = 50
filter = 'test(=services::grype_scanner::tests::test_prepare_local_oci_layout_resolves_index_to_child_layout) | test(=services::storage_gc_service::tests::test_run_blob_gc_mark_is_idempotent_and_preserves_timestamp) | test(=api::handlers::approval::tests::gate_db::test_approval_distinct_approver_allowed) | test(=api::handlers::approval::tests::gate_db::test_approval_path_allows_rule_met) | test(=api::handlers::ansible::tests::test_ansible_upload_accepts_galaxy_cli_payload) | test(=api::handlers::ansible::tests::test_ansible_upload_rejects_sha256_mismatch) | test(=services::grype_scanner::tests::test_prepare_local_oci_layout_materializes_manifest_and_blobs) | test(=api::handlers::promotion::tests::gate_db::test_bulk_promote_rule_met_and_unmet) | test(=api::handlers::approval::tests::gate_db::test_approval_path_skip_policy_check_override) | test(=api::handlers::approval::tests::gate_db::test_approval_cross_tenant_target_blocked) | test(=api::handlers::ansible::tests::test_ansible_download_serves_local_artifact) | test(=api::handlers::ansible::tests::test_ansible_upload_rejects_bad_filename) | test(=api::handlers::approval::tests::gate_db::test_approval_path_blocks_rule_unmet) | test(=api::handlers::promotion::tests::gate_db::test_single_promote_rule_met_promotes) | test(=api::handlers::promotion::tests::gate_db::test_single_promote_same_tenant_allowed) | test(=api::handlers::promotion::tests::gate_db::test_single_promote_scoped_token_with_grant_allowed) | test(=api::handlers::promotion::tests::gate_db::test_single_promote_skip_policy_check_override) | test(=api::handlers::repositories::tests::collect_repo_oci_upload_temp_keys_drains_large_backlog) | test(=api::handlers::proxy_helpers::tests::test_stage_and_put_artifact_stream_roundtrip) | test(=api::handlers::pypi::tests::pypi_upload_queues_sync_tasks_and_preserves_replication_metadata) | test(=services::storage_service::tests::test_list)'
PRIORITIES

profile_pool_size="${COVERAGE_PROFRAW_POOL_SIZE:-32}"
export LLVM_PROFILE_FILE_NAME="%${profile_pool_size}m.profraw"

phase coverage-env-start
echo "==> cargo llvm-cov show-env --sh"
source <(cargo llvm-cov show-env --sh)

# Keep the profile files inside cargo-llvm-cov's target dir so `report` finds
# them normally, but collapse nextest's process-per-test writes into an online
# merge pool instead of one .profraw per test process.
profile_dir="${LLVM_PROFILE_FILE%/*}"
export LLVM_PROFILE_FILE="${profile_dir}/%${profile_pool_size}m.profraw"
echo "==> LLVM_PROFILE_FILE=${LLVM_PROFILE_FILE}"

if [ "${COVERAGE_NO_CLEAN:-0}" = "1" ]; then
  echo "==> reusing instrumented coverage build artifacts"
  # Keep compiled objects/incremental state, but never merge counters from a
  # previous run into this run's report.
  find "${profile_dir}" -type f \
    \( -name '*.profraw' -o -name '*.profdata' \) -delete 2>/dev/null || true
else
  echo "==> cargo llvm-cov clean --workspace"
  cargo llvm-cov clean --workspace
fi

phase nextest-start
echo "==> cargo nextest run --workspace --lib"
# --status-level fail silences the ~12k per-test PASS lines that alone blow
# the 2MiB log clip; --final-status-level slow names the straggler tests in
# the end-of-run summary (the ~3-min tail the wall-clock plan is hunting).
cargo nextest run --workspace --lib \
  --test-threads "${COVERAGE_TEST_THREADS:-4}" \
  --status-level fail --final-status-level slow "${coverage_filter[@]}"

echo
phase profraw-footprint
echo "==> profraw pool footprint before report"
if [ -d "${profile_dir}" ]; then
  profraw_count="$(find "${profile_dir}" -maxdepth 1 -type f -name '*.profraw' | wc -l)"
  profraw_bytes="$(find "${profile_dir}" -maxdepth 1 -type f -name '*.profraw' -printf '%s\n' | awk '{ total += $1 } END { print total + 0 }')"
  echo "   dir: ${profile_dir}"
  echo "   files: ${profraw_count}"
  echo "   bytes: ${profraw_bytes}"
  du -sh "${profile_dir}" || true
  find "${profile_dir}" -maxdepth 1 -type f -name '*.profraw' -printf '   %f %s bytes\n' | sort | head -100
else
  echo "   profile dir missing: ${profile_dir}"
fi

echo
phase report-start
echo "==> cargo llvm-cov report --lcov"
cargo llvm-cov report --lcov --output-path /tmp/lcov.info

echo
phase summary-start
echo "==> overall coverage summary"
cargo llvm-cov report --summary-only

echo
phase floor-start
echo "==> overall floor: lines >= ${TOTAL_MIN:-50}%"
cargo llvm-cov report --fail-under-lines "${TOTAL_MIN:-50}"

echo
phase diff-coverage-start
echo "==> new-code coverage gate: changed backend/src lines >= ${NEW_CODE_MIN:-70}%"
BASE="${COVERAGE_BASE:-}"
if [ -z "${BASE}" ]; then
  # Default: the merge-base with main, so the gate reports coverage of the work
  # this branch is trying to land upstream.
  BASE="$(git -C /work merge-base main HEAD 2>/dev/null \
    || git -C /work merge-base origin/main HEAD 2>/dev/null \
    || git -C /work rev-parse main 2>/dev/null \
    || git -C /work rev-parse origin/main 2>/dev/null \
    || true)"
fi
if [ -z "${BASE}" ]; then
  echo "   no base ref found; set COVERAGE_BASE=<ref> to enable the new-code gate"
  exit 0
fi
echo "   diffing changed lines against: ${BASE}"
MERGE_BASE="${BASE}" LCOV=/tmp/lcov.info NEW_CODE_MIN="${NEW_CODE_MIN:-70}" \
  python3 /work/ci/local-ci/diff-coverage.py
phase done
