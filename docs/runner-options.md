# Runner Options

Artifact Keeper backend and web images are large enough that runner placement and
cache design matter. The reference pattern assumes self-hosted runners with a
remote BuildKit builder and registry-backed caches.

## Why Custom Runners

Use custom runners when you need:

- Large persistent BuildKit caches.
- Access to an internal registry and smoke Kubernetes cluster.
- Predictable CPU, memory, disk, and network characteristics.
- Secret boundaries that separate validate-only PRs from trusted publish paths.
- Native cosign and Trivy binaries on daemonless runners.

A warm `mode=max` registry cache can turn large rebuilds from minutes into
seconds for source-only changes, while still preserving an external cache that
survives runner pod replacement.

```mermaid
%%{init: {"theme": "base", "themeVariables": {"fontSize": "18px", "fontFamily": "Inter, ui-sans-serif, system-ui", "primaryTextColor": "#17212b", "lineColor": "#53616f"}} }%%
flowchart TB
  pr@{ shape: doc, label: "Pull request<br/>or dispatch" }
  gate@{ shape: diam, label: "Trusted<br/>publish path?" }
  validate@{ shape: lin-rect, label: "Validate only<br/>no secrets" }
  runner@{ shape: fr-rect, label: "Repo-scoped runner<br/>Gitea or ARC" }
  buildkit@{ shape: h-cyl, label: "Rootless BuildKit<br/>remote builder" }
  cache@{ shape: cyl, label: "Registry cache<br/>mode=max" }
  publish@{ shape: lin-rect, label: "Build + push<br/>backend / web" }
  sign@{ shape: hex, label: "Scan + sign<br/>verify" }
  smoke@{ shape: win-pane, label: "Scoped smoke<br/>namespace" }

  pr --> gate
  gate -- no --> validate
  gate -- yes --> runner --> buildkit --> publish --> sign --> smoke
  buildkit <--> cache
  publish --> cache

  classDef source fill:#dff3ff,stroke:#277da1,stroke-width:2px,color:#102a43,font-size:18px
  classDef policy fill:#fff1c7,stroke:#d99a00,stroke-width:2px,color:#3b2f12,font-size:18px
  classDef build fill:#ffe2dc,stroke:#d6452f,stroke-width:2px,color:#4a1710,font-size:18px
  classDef registry fill:#e9defa,stroke:#7c3aed,stroke-width:2px,color:#27133f,font-size:18px
  classDef deploy fill:#dff7e7,stroke:#238636,stroke-width:2px,color:#12351f,font-size:18px
  class pr source
  class gate,validate,sign policy
  class runner,buildkit,publish build
  class cache registry
  class smoke deploy
```

## Gitea Actions Pattern

The homelab implementation uses repository-scoped Gitea Actions runners. The
important reusable details are:

- Use repository-scoped labels such as `artifact-keeper-builder`; do not expose
  these runners as a general `ubuntu-latest` pool.
- Run jobs in host mode inside a hardened runner image, not Docker-in-Docker.
- Pair each runner with a rootless BuildKit daemon and drive it with buildx using
  a remote builder endpoint.
- Export/import BuildKit cache to an internal registry project such as
  `artifact-keeper-cache`.
- Keep the Kubernetes smoke ServiceAccount narrowly scoped. A fixed smoke
  namespace with namespaced admin rights is simpler and safer than granting
  cluster-wide namespace creation to CI.
- Put registry push credentials, cosign keys, and sync-bot credentials in
  repository Actions secrets. Do not pass them as runner-wide environment.
- Treat bot-authored upstream-sync PRs as validate-only unless a maintainer
  explicitly authorizes deployment.

## GitHub Actions ARC Pattern

For a GitHub-hosted version, use Actions Runner Controller (ARC) with a dedicated
runner scale set for this repository. Keep the same trust boundaries:

- Restrict the scale set to this repository or organization path.
- Use a custom runner image containing buildx, git, git-subtree, helm, kubectl,
  cosign, Trivy, make, and any language toolchains needed by source checks.
- Run a rootless BuildKit sidecar or a separately managed BuildKit service.
- Use registry-backed `mode=max` caches rather than relying only on pod-local
  ephemeral storage.
- Mount only the ServiceAccount permissions needed for the smoke namespace.
- Use GitHub Environments or workflow conditions so untrusted bot PRs cannot
  access registry, signing, or cluster secrets.
- Pin third-party actions by commit SHA.

ARC can autoscale build capacity while keeping this repository's expensive image
builds away from generic shared runners. It is a good fit for organizations that
want the same vendored deployment pattern but use GitHub as the source authority
instead of Gitea.

## Cache and Storage Notes

Use two cache layers:

- Pod or host-local cache for fast repeated builds on the same runner.
- Registry cache for durable warm starts after runner replacement or reschedule.

The registry cache is the recovery layer. Do not rely on a single node-local
cache as the only copy of build acceleration state, and do not put release
artifacts in the same retention bucket as scratch images.

## Minimal Secret Set

A trusted publish path usually needs:

| Secret | Scope | Purpose |
| --- | --- | --- |
| `HARBOR_REGISTRY` or equivalent | publish workflow | registry hostname |
| `HARBOR_USERNAME` | publish workflow | push/pull robot |
| `HARBOR_PASSWORD` | publish workflow | push/pull robot secret |
| `COSIGN_PRIVATE_KEY` | sign step only | image signing |
| `COSIGN_PASSWORD` | sign step only | image signing |
| `SYNC_BOT_TOKEN` | upstream sync only | open/update vendor PRs |
| `SYNC_BOT_SIGNING_KEY` | upstream sync only | signed bot commits |

Use your platform's secret store names if they differ. The principle is more
important than the exact variable names: validate-only jobs do not receive
publish or signing secrets.
