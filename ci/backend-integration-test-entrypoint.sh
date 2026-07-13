#!/usr/bin/env bash
# Shared runtime command for the pre-built backend integration-test image.
set -euo pipefail

readonly test_target="${TEST_TARGET:?TEST_TARGET is required}"

for attempt in $(seq 1 10); do
  if sqlx migrate run --source backend/migrations; then
    exec "/test-bin/${test_target}" --ignored --test-threads=1
  fi
  if [[ "${attempt}" -eq 10 ]]; then
    echo "sqlx migrate run failed after ${attempt} attempts" >&2
    exit 1
  fi
  echo "migrate attempt ${attempt} failed; retrying" >&2
  sleep 3
done
