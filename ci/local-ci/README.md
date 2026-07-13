# Backend CI mirror (local + Gitea runners)

A small, well-cached Docker mirror of the upstream backend CI jobs in
[`artifact-keeper/.github/workflows/ci.yml`](../../artifact-keeper/.github/workflows/ci.yml),
so backend feature work can be iterated on locally with the **same gates the
reviewer runs** — in particular changed-line coverage.

The coverage gate runs automatically in Gitea's `publish-ci` workflow. Because
the repository runners are daemonless, that lane uses
[`Dockerfile.runner`](Dockerfile.runner) with their persistent rootless
BuildKit cache and a short-lived Postgres deployment in the RBAC-confined
`ak-smoke` namespace. The job uploads `coverage.log` and `lcov.info` as a
`backend-coverage-*` artifact.

The `backend-integration` job runs the curated, Postgres-only
`backend/tests/*.rs` targets, but *not* by repeating a BuildKit compile per
target the way `backend-coverage` does. `backend-integration-build` compiles
every integration-test binary exactly once (`test-artifacts` stage of
[`Dockerfile.runner`](Dockerfile.runner): `cargo test --tests --no-run`, then
each compiled executable is copied out of the cargo target cache mount into
`/test-bin/<name>`) and pushes the result to Harbor
(`ci/backend-test-image-build.sh`). `backend-integration`'s matrix then has
one leg per target, each running `ci/backend-integration-run-compose.sh` on
the capacity-one `artifact-keeper-compose` runner. Each leg starts an isolated
Postgres service, pulls the already-built image, executes exactly one pre-built
binary (`/test-bin/<name> --ignored`), records timing and cleanup evidence, and
tears down its entire Compose project. Shared lifecycle handling bounds every
teardown command, removes registry credentials before cleanup, and turns a
passing test into a failed job if any container, volume, or project network
remains. The test-runner is an unsigned,
short-lived CI artifact, and consumers receive its immutable Harbor digest
rather than relying on its mutable short-SHA tag. There is no per-leg compile.
The former Kubernetes matrix was removed after paired all-nine and repeat
Compose runs proved equivalent results with substantially less runner time and
noise. See the integration job's header comments in
`.gitea/workflows/publish-ci.yml` for the current target list and what's
deliberately excluded. Each leg uploads its `integration.log` as a
`backend-integration-<target>-*` artifact.

`ci/backend-quality-k8s.sh QUALITY_MODE=integration` (the original
compile-and-run-in-one-BuildKit-build path) still works standalone for
manual/ad-hoc runs — it's just no longer what Gitea CI itself calls.
`ci/backend-integration-run-k8s.sh` is likewise retained as a manual rollback
tool, but the publish workflow does not invoke it.

The runner variant uses eight compiler jobs, incremental compilation,
`cargo llvm-cov --no-clean`, and eight nextest threads (the lab builders have
materially more memory than upstream's constrained ARC pods). It deletes old
LLVM profile counters before each run, retaining compiled objects without
allowing stale hits to inflate the report. It also excludes two pre-existing
environment-sensitive tests in coverage mode: the OTLP constructor with a
hard-coded localhost URI, and the filesystem-unwritable probe that runs as root
inside BuildKit. These exceptions do not touch the feature tests under coverage.

## What it reproduces

| Upstream job | Local mode | What runs |
|---|---|---|
| `test-backend-unit` | `make local-test` | Postgres → `sqlx migrate run` → `cargo test --workspace --lib --test-threads=1` |
| `coverage` | `make local-coverage` | the above tests under `cargo llvm-cov nextest --lib`, the **≥50% overall floor**, and the **≥70% new-code (diff) gate** |
| (nightly/e2e) | `TEST=<name> make local-integration` (locally) / `backend-integration-build` + `backend-integration` matrix (Gitea, curated target list, build-once-run-many) | a DB-backed `tests/` suite `--lib` skips, run with `--ignored` for hermetic targets that need Postgres or local mock services. |

The new-code gate is a faithful port of upstream's "New code coverage gate"
([diff-coverage.py](diff-coverage.py)): it measures coverage on **changed
`backend/src/` lines only** and lists the uncovered ones so you know exactly
what to add a `--lib` unit test for. Only `src/` `#[cfg(test)]` tests count
toward coverage — integration tests under `backend/tests/` are a separate target
and, like upstream, do not move the coverage number.

> Not reproduced (yet): the jscpd 3% code-duplication gate and the full protocol
> smoke matrix. The separate k8s-native publish smoke remains responsible for
> real pypi/npm/cargo clients against the built backend image.

## Usage

```sh
make local-ci-build      # one-time: build the toolchain image (rust 1.93 + llvm-cov + nextest + sqlx-cli)
make local-test          # run the backend lib tests
make local-coverage      # run tests + coverage + the new-code gate
TEST=<name> make local-integration  # run one ignored DB-backed tests/ target
make local-ci-down       # drop the postgres container and the cache volumes
```

Knobs (env):

```sh
NEW_CODE_MIN=70 make local-coverage          # new-code threshold (default 70)
TOTAL_MIN=50 make local-coverage             # overall floor (default 50)
COVERAGE_BASE=<git-ref> make local-coverage  # diff base (default: merge-base with main)
COVERAGE_NEXTEST_FILTER=<expr> make local-coverage  # override the default narrow exclusions
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
- `backend-integration-build` pushes the test-runner image to
  `artifact-keeper-ci/artifact-keeper-backend-test-runner:<short-sha>` (same
  Harbor project as the CI-built backend/web images) with a
  `--cache-to`/`--cache-from` registry build cache under
  `artifact-keeper-cache`, mirroring `ci/build-images.sh`'s conventions. It's
  a throwaway CI artifact — unsigned, unscanned, one tag per run — so it
  relies on Harbor's project-level retention policy for `artifact-keeper-ci`
  to reap old tags rather than any cleanup step here.
