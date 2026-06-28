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
