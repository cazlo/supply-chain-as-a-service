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
artifact-keeper/       full-history upstream subtree
artifact-keeper-web/   full-history upstream subtree
artifact-keeper-iac/   full-history upstream subtree
UPSTREAM.md            imported revisions and local patch status
patches/               local patches awaiting upstream disposition
```

See [UPSTREAM.md](UPSTREAM.md) for pinned revisions, provenance, verification,
and non-squashed subtree synchronization commands.

Common vendoring commands are `make vendor-check`, `make vendor-status`, and
`make vendor-update NAME=<name> REF=<reviewed-ref> TAG=<tag-or-dash>`.
Run `make source-check-chart` to lint/render the vendored chart without
modifying the imported trees. Run `make source-smoke` for the k8s-native smoke
gate (ephemeral chart install plus the vendored pypi, npm, and cargo client Jobs;
needs kubectl + helm + a cluster), or `make source-smoke-compose` for the
cluster-free Docker Compose equivalent.

`make ci-publish` is the local equivalent of the `publish-ci` Gitea workflow.
The workflow triggers automatically on pull requests (and on manual dispatch) so
every proposed change gets a full chart-lint, parallel backend/web build, and
k8s smoke before merging. It runs backend and web as independent parallel jobs so
the two builders can share the work. Each imports and exports its retained Harbor
BuildKit cache, attaches BuildKit SBOM and mode-max provenance attestations,
pushes a source-derived tag, and writes the immutable image digest plus build
inputs to its retained build record. The command requires `HARBOR_REGISTRY`,
`HARBOR_USERNAME`, and `HARBOR_PASSWORD`; keep those values in repository
Actions secrets rather than source control.
