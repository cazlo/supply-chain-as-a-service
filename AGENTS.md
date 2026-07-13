# Supply Chain as a Service — Agent Guide (AGENTS.md)

Welcome, AI Agent. This repo is the **private source, CI, and image-promotion
workspace** for the Artifact Keeper supply-chain lab. It vendors three upstream
projects as full-history subtrees, builds and signs their images on private
Gitea runners, scans them, and promotes them to the homelab Harbor. GitHub is a
private source backup only — **CI runs on Gitea, not GitHub**.

## Repository structure

- [artifact-keeper/](artifact-keeper/) — backend (Rust) upstream subtree.
- [artifact-keeper-web/](artifact-keeper-web/) — web UI (Next.js) upstream subtree.
- [artifact-keeper-iac/](artifact-keeper-iac/) — IaC + the Helm chart at
  [artifact-keeper-iac/charts/artifact-keeper/](artifact-keeper-iac/charts/artifact-keeper/).
- [ci/](ci/) — shared build, scan, sign, smoke, and vendor-sync scripts.
- [.gitea/workflows/](.gitea/workflows/) — Gitea Actions entry points.
- [vendor/upstreams.tsv](vendor/upstreams.tsv) / [UPSTREAM.md](UPSTREAM.md) —
  pinned upstream revisions and provenance.

The three top-level app directories are **vendored subtrees**. Do not hand-edit
them to track upstream; import changes via `make vendor-update` so provenance in
[UPSTREAM.md](UPSTREAM.md) and [vendor/upstreams.tsv](vendor/upstreams.tsv) stays
truthful. Local fixes that must diverge from upstream belong in `patches/` with a
note on upstream disposition. Files you *do* own and edit directly:
[ci/](ci/), [.gitea/workflows/](.gitea/workflows/), [Makefile](Makefile), and
the chart's lab values.

## Development workflow

- **Ship changes via PRs to the `gitea` remote**, not GitHub `origin`. Gitea is
  the CI trigger and (post-transition) the authority; `origin` is a backup.
- **Prefer the CI runners over local builds** — the runners have the BuildKit
  cache and Harbor push/sign secrets; the local box is slow and unprivileged.
- `publish-ci` runs automatically on every PR (and on manual dispatch). Human/
  dispatch PRs build → scan (Trivy) → sign (cosign) → verify → Compose runtime
  gates and push to Harbor; bot-authored PRs (the upstream-sync bot) are
  validate-only and never receive secrets or get deployed.

## Common commands

Vendoring (subtrees):
- `make vendor-status` — show imported vs upstream revisions.
- `make vendor-check` — verify the working tree matches the pinned revisions.
- `make vendor-update NAME=<name> REF=<reviewed-ref> TAG=<tag-or-dash>` — import
  a reviewed upstream revision for one subtree.
- `make vendor-sync` — local dry-run of the scheduled upstream-sync (needs
  `GITEA_SERVER`/`GITEA_TOKEN`); imports fast-forward upstreams without pushing.

Source checks, smoke, and publish:
- `make source-check-chart` — lint/render the vendored chart without touching
  the subtrees. Also `source-check-backend` / `source-check-web` / `source-check`.
- `make source-smoke` — manually dispatched k8s-native chart smoke: ephemeral
  `helm install` + vendored pypi/npm/cargo client Jobs. PR publish CI splits
  backend build/scan/sign/verify onto `artifact-keeper-builder` from runtime
  smoke on `artifact-keeper-compose`, consuming the exact signed digest with no
  Podman-side build. `make source-smoke-compose` remains the workstation entry
  point.
- `make web-e2e-ci` — runtime-only Playwright Compose lane. It requires exact
  backend, web, and E2E-runner digest refs produced by the builder jobs.
  `make web-e2e-k8s-ci` retains the old chart/Job path for manual rollback.
- `make ci-publish` — local equivalent of the `publish-ci` workflow; requires
  `HARBOR_REGISTRY`/`HARBOR_USERNAME`/`HARBOR_PASSWORD` (keep these in Gitea
  Actions secrets, never in source).

## Where things run

- **Images** publish to Harbor `oci.cazlab.link`: `artifact-keeper-ci` (per-PR
  scratch), `artifact-keeper-cache` (BuildKit cache), with `-staging` /
  `-release` projects reserved for promotion.
- **Runners + Harbor provisioning** live in the homelab GitOps repo
  `cyberdyne-home-assistant` under `apps/gitea-runners/`.
- **The cluster deploy** of this chart is GitOps in `cyberdyne-home-assistant`
  at `apps/artifact-keeper/` (Flux pulls this chart from Gitea and runs the
  lab's signed images). Chart/values changes here flow to the cluster only after
  that repo's HelmRelease is updated to a newer published image tag.

## Conventions

- Keep secrets out of source — Harbor/cosign/Gitea creds live in Gitea Actions
  secrets and homelab out-of-band Secrets, not in this repo.
- Push reviewed `main` changes to both remotes during the transition; never
  configure bidirectional mirroring (one-way replication to GitHub only).
- In Markdown summaries, link files as `[path](path)` rather than wrapping them
  in backticks, matching the homelab repos' house style.
