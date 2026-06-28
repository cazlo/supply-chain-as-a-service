# Vendored upstream sources

The three Artifact Keeper repositories are imported as full-history Git
subtrees. Do not use the `--squash` option when adding or updating them; keeping
the upstream ancestry makes later synchronization and contribution work easier.

## Current imports

The machine-readable source of truth is
[vendor/upstreams.tsv](vendor/upstreams.tsv). A `-` in its tag column means the
reviewed commit had no containing release tag at import time. Each vendored
prefix retains its upstream `LICENSE` file.

Local build identities and image digests will be recorded when reproducible CI
is introduced. There are currently no local behavioral patches, related
upstream issues, or pull requests.

## Clean snapshot validation

The pinned snapshots passed the following unmodified-source gates on 2026-06-27:

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

The imported upstream commits remain reachable through the subtree merge
parents. This check requires no network access:

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

## Update a subtree

Start from a clean worktree. The update command fetches the reviewed ref, rejects
non-fast-forward history, performs a non-squashed subtree merge, explicitly
signs that merge, updates the lock file, and creates a second signed provenance
commit:

```sh
make vendor-update NAME=artifact-keeper REF=<reviewed-ref> TAG=<release-tag-or-dash>
```

Review both commits and run `make vendor-check` before pushing. Never edit an
imported tree anonymously. Make a behavioral change in an upstream fork/branch,
record its issue or pull request and disposition here, and then import that
exact commit through the subtree.
