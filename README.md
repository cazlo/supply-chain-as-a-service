# supply-chain-as-a-service

Private source, CI, and image-promotion workspace for the Artifact Keeper
supply-chain lab. Builds and publishing run only on private Gitea runners and
Harbor; GitHub is a private source backup and does not run CI.

## Remotes

- `origin`: private GitHub repository and current transition authority.
- `gitea`: private Gitea repository and CI trigger.

During the transition, push each reviewed `main` change to both remotes. After
the Gitea runners are proven, make Gitea authoritative and use only one-way
replication to GitHub for backup. Do not configure bidirectional mirroring.

## Planned layout

```text
.gitea/workflows/      Gitea Actions entry points
ci/                    shared build, test, and publish scripts
artifact-keeper/       squashed upstream subtree
artifact-keeper-web/   squashed upstream subtree
artifact-keeper-iac/   squashed upstream subtree
UPSTREAM.md            imported revisions and local patch status
patches/               local patches awaiting upstream disposition
```
