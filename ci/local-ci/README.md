# Backend CI mirror (local + Gitea runners)

A small, well-cached Docker mirror of the upstream backend CI jobs in
[`artifact-keeper/.github/workflows/ci.yml`](../../artifact-keeper/.github/workflows/ci.yml),
so the age-gate work can be iterated on locally with the **same gates the
reviewer runs** — in particular the coverage gates the PR was flagged on.

The same gates run automatically in Gitea's `publish-ci` workflow. Because the
repository runners are daemonless, that lane uses
[`Dockerfile.runner`](Dockerfile.runner) with their persistent rootless
BuildKit cache and a short-lived Postgres deployment in the RBAC-confined
`ak-smoke` namespace. The two jobs upload `integration.log`, `coverage.log`,
and `lcov.info` as `backend-integration-*` / `backend-coverage-*` artifacts.

The runner variant uses eight compiler jobs, incremental compilation,
`cargo llvm-cov --no-clean`, and eight nextest threads (the lab builders have
materially more memory than upstream's constrained ARC pods). Integration and
coverage are separate Gitea jobs, so the two builders can execute them in
parallel while preserving upstream's `--lib`-only coverage definition. It
deletes old LLVM profile counters before each run, retaining compiled objects
without allowing stale hits to inflate the report. It
also excludes only
`telemetry::tests::test_build_span_exporter_grpc`: that pre-existing test's
hard-coded localhost OTLP URI is rejected in rootless BuildKit, after 11,744
other lib tests passed. This exception does not apply to local runs and does not
touch the age-gate unit or integration suites.

## What it reproduces

| Upstream job | Local mode | What runs |
|---|---|---|
| `test-backend-unit` | `make local-test` | Postgres → `sqlx migrate run` → `cargo test --workspace --lib --test-threads=1` |
| `coverage` | `make local-coverage` | the above tests under `cargo llvm-cov nextest --lib`, the **≥50% overall floor**, and the **≥70% new-code (diff) gate** |
| (nightly/e2e) | `make local-integration` | the DB-backed `tests/` suites `--lib` skips — defaults to `age_gate_tests` (`--ignored`), the target that runs [patches/0003]. Override with `TEST=<name>`. |

The new-code gate is a faithful port of upstream's "New code coverage gate"
([diff-coverage.py](diff-coverage.py)): it measures coverage on **changed
`backend/src/` lines only** and lists the uncovered ones so you know exactly
what to add a `--lib` unit test for. Only `src/` `#[cfg(test)]` tests count
toward coverage — integration tests under `backend/tests/` are a separate target
and, like upstream, do not move the coverage number.

> Not reproduced (yet): the jscpd 3% code-duplication gate and the full protocol
> smoke matrix. The age-gate `--ignored` DB/wiremock integration suite runs here;
> the separate k8s-native publish smoke remains responsible for real pypi/npm/
> cargo clients against the built backend image.

## Usage

```sh
make local-ci-build      # one-time: build the toolchain image (rust 1.93 + llvm-cov + nextest + sqlx-cli)
make local-test          # run the backend lib tests
make local-coverage      # run tests + coverage + the new-code gate
make local-ci-down       # drop the postgres container and the cache volumes
```

Knobs (env):

```sh
NEW_CODE_MIN=70 make local-coverage          # new-code threshold (default 70)
TOTAL_MIN=50 make local-coverage             # overall floor (default 50)
COVERAGE_BASE=<git-ref> make local-coverage  # diff base (default: merge-base with main == the age-gate patches)
```

## Caching

Only the first `local-coverage` pays the full backend compile. Two named
volumes persist across runs:

- `ak-cargo` — the cargo registry/git download cache (`CARGO_HOME`)
- `ak-target` — the compile target dir (incl. `target/llvm-cov-target`)

The repo is mounted into the container; all build output lands in the volumes
(and `lcov.info` in the container's `/tmp`), so your working tree stays clean.
`make local-ci-down` clears the volumes for a cold rebuild.

## Notes

- Toolchain is pinned to **rust 1.93.0** to match the production image
  (`artifact-keeper/docker/Dockerfile.backend`).
- `SQLX_OFFLINE=true` uses the committed `.sqlx` cache, so the build needs no
  database; the Postgres service is only for the DB-backed lib tests at run time
  (the same reason upstream provides it).
