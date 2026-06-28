# Vendored upstream sources

The three Artifact Keeper repositories are imported as full-history Git
subtrees. Do not use the `--squash` option when adding or updating them; keeping
the upstream ancestry makes later synchronization and contribution work easier.

## Current imports

| Prefix | Upstream | Revision | Release/tag | Imported | License |
|---|---|---|---|---|---|
| `artifact-keeper/` | <https://github.com/artifact-keeper/artifact-keeper.git> | `ea6f5ed686ea2783bcaddd67c9e22bcb66d607a8` | `v1.2.1` | 2026-06-27 | [LICENSE](artifact-keeper/LICENSE) |
| `artifact-keeper-web/` | <https://github.com/artifact-keeper/artifact-keeper-web.git> | `3cfc8dd6665969bf53aa34481ac1268c540b8cc6` | no containing tag at import | 2026-06-27 | [LICENSE](artifact-keeper-web/LICENSE) |
| `artifact-keeper-iac/` | <https://github.com/artifact-keeper/artifact-keeper-iac.git> | `19fddefd17d91df77ecad0526f388655435545ef` | no containing tag at import | 2026-06-27 | [LICENSE](artifact-keeper-iac/LICENSE) |

Local build identities and image digests will be recorded when reproducible CI
is introduced. There are currently no local behavioral patches, related
upstream issues, or pull requests.

## Verify the pinned snapshots

The imported upstream commits remain reachable through the subtree merge
parents. This check requires no network access:

```sh
ci/check-vendored-upstreams.sh
```

## Fetch and inspect an upstream update

Use temporary remote-tracking refs so fetching does not alter the vendored
trees:

```sh
git fetch https://github.com/artifact-keeper/artifact-keeper.git main:refs/remotes/vendor/artifact-keeper
git fetch https://github.com/artifact-keeper/artifact-keeper-web.git main:refs/remotes/vendor/artifact-keeper-web
git fetch https://github.com/artifact-keeper/artifact-keeper-iac.git main:refs/remotes/vendor/artifact-keeper-iac

git log --oneline ea6f5ed686ea2783bcaddd67c9e22bcb66d607a8..refs/remotes/vendor/artifact-keeper
git log --oneline 3cfc8dd6665969bf53aa34481ac1268c540b8cc6..refs/remotes/vendor/artifact-keeper-web
git log --oneline 19fddefd17d91df77ecad0526f388655435545ef..refs/remotes/vendor/artifact-keeper-iac
```

Review release notes, licenses, dependency changes, and the diff before choosing
the exact update commit.

## Update a subtree

Pull the reviewed revision without squashing, then update the corresponding row
above in the same change:

```sh
git subtree pull --prefix=artifact-keeper https://github.com/artifact-keeper/artifact-keeper.git <reviewed-ref>
git subtree pull --prefix=artifact-keeper-web https://github.com/artifact-keeper/artifact-keeper-web.git <reviewed-ref>
git subtree pull --prefix=artifact-keeper-iac https://github.com/artifact-keeper/artifact-keeper-iac.git <reviewed-ref>
```

Run [ci/check-vendored-upstreams.sh](ci/check-vendored-upstreams.sh) after the
recorded revisions are updated. Never edit an imported tree anonymously. Make a
behavioral change in an upstream fork/branch, record its issue or pull request
and disposition here, and then import that exact commit through the subtree.
