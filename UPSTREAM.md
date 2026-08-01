# Vendored upstream sources

The three Artifact Keeper repositories are imported content-only: each vendored
prefix holds the exact tree of one reviewed upstream commit, imported as an
ordinary single-parent commit. Upstream ancestry is deliberately kept out of
this history, so `main` stays linear and the public mirror carries no upstream
commit graph. The recorded revision identifies the imported commit; it is not
reachable from `HEAD`.

## Current imports

The machine-readable source of truth is
[vendor/upstreams.tsv](vendor/upstreams.tsv). A `-` in its tag column means the
reviewed commit had no containing release tag at import time. Each vendored
prefix retains its upstream `LICENSE` file.

| prefix | tag | revision | imported |
| --- | --- | --- | --- |
| `artifact-keeper/` | `v1.7.0` | `13b28fc7049a634efcae99884d761641151ef538` | 2026-08-01 |
| `artifact-keeper-web/` | `v1.6.0` | `e86b5ff4f990a15150e5585c21d0b0345fa54ec3` | 2026-08-01 |
| `artifact-keeper-iac/` | `artifact-keeper-1.9.4` | `6339c005d9a732576f975be07cf39f02ee6135ef` | 2026-08-01 |

The backend `v1.7.0` tag differs from the upstream main tip `9cbd7efc` only in
`.github/workflows/release.yml`. There is no web `v1.7.0` release; `v1.6.0` is
the newest web tag. The IaC pin carries chart version `1.9.4` with `appVersion`
`1.6.0`.

## Local patches

| prefix | patch | upstream issue or PR | disposition |
| --- | --- | --- | --- |

None. Every vendored prefix is byte-identical to its upstream tag; `make
vendor-check` proves it. Local build identities and image digests will be
recorded when reproducible CI is introduced.

## Clean snapshot validation

The gates below are the standing unmodified-source gates. They last recorded a
full pass on 2026-06-27, against the original `ea6f5ed` / `3cfc8dd` snapshots;
the results have not been re-recorded for the current pins:

- backend Docker `builder` target with identity
  `artifact-keeper-backend:source-check-ea6f5ed` and application version
  `v1.2.1`;
- web Docker `build` target with identity
  `artifact-keeper-web:source-check-3cfc8dd`, including its production Next.js
  compile, TypeScript check, and static-page generation;
- Helm strict lint plus an offline Kubernetes client render using the chart's
  lean CI values;
- the backend image built and serving the vendored `pypi`, `npm`, and `cargo`
  Docker Compose smoke clients, all passing against a freshly bootstrapped
  registry.

Run all three fast gates, or one named gate, with:

```sh
make source-check
make source-check-backend
make source-check-web
make source-check-chart
```

The smoke gate runs the vendored `pypi`, `npm`, and `cargo` native clients
against a freshly built backend. The pull-request gate (`make source-smoke`,
`ci/smoke-k8s.sh`) is k8s-native: it helm-installs the vendored chart with its CI
values into an ephemeral namespace, bootstraps the test repositories, runs the
clients as Jobs over cluster HTTP, then deletes the namespace. It needs `kubectl`
and `helm` pointed at a cluster and the backend image reachable by that cluster.
A workstation Docker Compose equivalent is kept for cluster-free runs:

```sh
make source-smoke          # k8s-native (PR gate); needs kubectl + helm + cluster
make source-smoke-compose  # local Docker Compose equivalent
```

The web dependency install reported seven audit findings (one low, four
moderate, and two high). The clean upstream snapshot still builds; vulnerability
evaluation and disposition belong to the reproducible CI milestone.

## Verify the pinned snapshots

The check compares each vendored prefix with the tree of its recorded revision
and fails on any byte of drift. It requires no network access, but it does need
the recorded commits present locally — fetch them into `refs/vendor/*` on a
fresh clone, since content-only imports leave them unreachable from `HEAD`:

```sh
make vendor-check
```

## Fetch and inspect an upstream update

Fetch each default branch into isolated refs and report whether the pinned
commit is current, behind, or diverged. This does not alter the vendored trees:

```sh
make vendor-status
```

Review release notes, licenses, dependency changes, and the diff before choosing
the exact update commit. Inspect one fetched range with:

```sh
git log --oneline <recorded-revision>..refs/vendor-sync/<name>/latest
```

## Re-pin a vendored prefix

Start from a clean worktree. The update command fetches the reviewed ref,
verifies that the release tag resolves to it, replaces the prefix with that
commit's tree, signs the re-pin commit, updates the lock file, and creates a
second signed provenance commit. The reviewed revision does not have to be a
fast-forward from the current pin, and no merge commit is created:

```sh
make vendor-update NAME=artifact-keeper REF=<reviewed-ref> TAG=<release-tag-or-dash>
```

Review both commits and run `make vendor-check` before pushing. Never edit an
imported tree anonymously. Make a behavioral change in an upstream fork/branch,
record its issue or pull request and disposition in the local-patches table
above, and then import that exact commit as its own content-only re-pin.
