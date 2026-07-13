# Podman Compose Runner Design

This guide describes a Kubernetes-hosted CI runner that executes trusted,
runtime-only Docker Compose jobs without mounting a node container socket and
without running a privileged Docker daemon. It is a reusable architecture
pattern rather than a copy of any one deployment: names, registry locations,
node labels, credentials, sizing observations, and internal network details are
intentionally omitted or replaced with examples.

The design has been exercised with database integration tests, native package
client tests, and Playwright browser tests. Compilation, image construction,
scanning, signing, and promotion remain on a separate BuildKit-capable runner
pool. That division is fundamental: the Podman pool is an ephemeral runtime
substrate, not a general replacement for a build farm.

## Design goals

- Run ordinary Docker CLI and Docker Compose workflows with minimal changes.
- Give every workflow job a private container engine and private Compose state.
- Avoid privileged Pods, host container sockets, `hostPath`, host namespaces,
  and host devices.
- Keep the workflow container non-root and remove Kubernetes API credentials.
- Constrain the Podman service with a Kubernetes Pod user namespace.
- Scale horizontally with one workflow at a time per engine.
- Pull application and test images by immutable digest; do not rebuild them in
  the runtime pool.
- Guarantee bounded cleanup on success, test failure, timeout, and termination.
- Preserve an explicit, separately tested Kubernetes release or chart gate.

## Non-goals

- Building large application images through Podman's Docker compatibility API.
- Providing an untrusted, internet-wide shared runner service.
- Treating the Podman API socket as a low-privilege interface.
- Replacing production Kubernetes deployment validation with Compose.
- Claiming equivalence with ARC's supported `dind` or `kubernetes` container
  modes.

## Alternatives and selection

Evaluate the simpler or stronger options first:

| Option | Main advantage | Reason it may not fit |
| --- | --- | --- |
| Node runtime socket mount | simplest Docker compatibility | grants the job control of the node engine and other workloads |
| Privileged Docker-in-Docker | familiar and broadly compatible | privileged Pod boundary and a second Docker-specific operating model |
| Rootless Podman sidecar | smallest sidecar privilege set | needs working subordinate IDs, nested user namespaces, storage, and user-mode networking on every node image |
| ARC Kubernetes mode | GitHub-supported container-job model | creates separate job Pods through Kubernetes API permissions; it is not Docker Compose semantics |
| Dedicated VM runner | clear isolation and easiest nested-container behavior | separate fleet lifecycle and slower elasticity than Kubernetes Pods |

Rootless Podman is worth proving first. The rootful-in-Pod-user-namespace
variant is a fallback for clusters where nested rootless storage or networking
cannot support the real application topology. Its justification depends on the
outer user namespace and the absence of host integration; without those
controls, choose a VM instead.

## Architecture

Each runner Pod contains two long-running containers and several shared
`emptyDir` volumes:

```mermaid
flowchart LR
  control[CI control plane]
  runner[Non-root runner container]
  socket[(Private Unix socket)]
  engine[Rootful Podman service]
  graph[(Ephemeral image and container store)]
  workspace[(Shared workspace at identical path)]
  jobs[Compose services and test containers]
  registry[OCI registry]

  control --> runner
  runner -->|Docker API| socket --> engine
  runner <--> workspace
  engine <--> workspace
  engine <--> graph
  engine --> jobs
  registry --> engine
```

The workflow container runs as a non-root UID. Docker CLI and Compose connect
to a Unix socket in a shared volume through `DOCKER_HOST`. The sidecar runs
rootful Podman, but UID 0 and its capabilities exist inside the outer Pod's
user namespace because the Pod sets `hostUsers: false`. Kubernetes maps that
identity to an unprivileged host UID range. Kubernetes documents both the
`hostUsers: false` opt-in and validation through `/proc/self/uid_map` in
[Use a User Namespace With a Pod](https://kubernetes.io/docs/tasks/configure-pod-container/user-namespaces/).

This is deliberately described as **rootful Podman inside a Pod user
namespace**, not rootless Podman. Those are different isolation mechanisms
with different storage, networking, and subordinate-ID requirements.

The Podman service exposes its Docker-compatible API only on the private Unix
socket. Podman documents that the API grants full control of the service and
therefore must be protected as a privileged interface; do not expose it on a
cluster Service or unauthenticated TCP port. See
[`podman system service`](https://docs.podman.io/en/latest/markdown/podman-system-service.1.html).

## Security boundary

The selected boundary combines several controls. No single item is sufficient
by itself.

### Pod boundary

- `hostUsers: false` creates a Pod user namespace.
- `hostNetwork`, `hostPID`, and `hostIPC` remain false.
- The Pod is not privileged and mounts no `hostPath`.
- No node Docker, containerd, or Podman socket is mounted.
- `automountServiceAccountToken: false` removes the default Kubernetes token.
- The Podman API socket exists only in an `emptyDir` shared by the two
  containers.
- The Podman graph store is an `emptyDir`; deleting the Pod deletes its engine
  state.
- NetworkPolicy starts from deny-by-default and allows only required DNS, CI
  control-plane, registry, and dependency endpoints.

### Container boundary

The runner container should use:

- a fixed non-root UID/GID;
- `allowPrivilegeEscalation: false`;
- all Linux capabilities dropped;
- `RuntimeDefault` seccomp;
- a writable workspace and home, with the injected tool directory read-only.

The Podman container needs a more capable security context to create inner
mount, network, PID, and IPC namespaces. A proven baseline is:

- `privileged: false`;
- root inside the Pod user namespace;
- only `SYS_ADMIN`, `NET_ADMIN`, and `SYS_PTRACE` added;
- unconfined seccomp and, on AppArmor nodes, an unconfined AppArmor profile;
- `procMount: Unmasked` where required by the runtime;
- `allowPrivilegeEscalation: true` inside the mapped Pod boundary.

These settings are intentionally conspicuous. Admission policy, Linux Security
Module behavior, CRI implementation, and Kubernetes version differ between
clusters. Validate the exact combination on every eligible node image and
reject the design if the Pod user namespace is absent. Never "make it work" by
adding `privileged: true`, a host runtime socket, or host devices.

### Trust boundary

Possession of the Podman socket is equivalent to administrative control of the
sidecar engine. The runner may start arbitrary containers, mount any path that
the sidecar can see, and inspect engine-managed data. Consequently:

- use one engine per runner Pod;
- set runner capacity to one;
- route only trusted-maintainer or otherwise authorized workflows to the pool;
- do not share an engine between repositories or security domains;
- inject registry and signing credentials only at job scope;
- keep signing keys off the runtime pool entirely when possible;
- use a distinct runner label or ARC runner scale set name.

## Filesystem and socket contract

Docker Compose resolves bind-mount source paths in the engine, not in the CLI
process. The checkout therefore must appear at the **same absolute path** in
both containers. Mount one shared volume, for example `/work`, into the runner
and Podman containers at `/work`, then configure the runner work directory
under that path.

Use separate volumes for:

| Volume | Runner mount | Podman mount | Purpose |
| --- | --- | --- | --- |
| workspace | `/work` | `/work` | checkout and Compose bind sources |
| socket | `/run/podman-ci` | `/run/podman-ci` | private API socket |
| graph | none | `/var/lib/containers` | ephemeral images, layers, containers |
| runner home | runner home | none | CLI config and temporary credentials |
| tools | read-only tools path | none | Docker CLI and Compose plugin |

Give every job a writable, job-qualified `DOCKER_CONFIG`. If the runner image
ships the Compose plugin in a read-only directory, copy only `config.json` and
symlink `cli-plugins` into the temporary config. Delete the entire temporary
directory during cleanup.

## Podman service configuration

Run one service indefinitely on the private socket:

```sh
podman system service --time=0 unix:///run/podman-ci/podman.sock
```

Set `DOCKER_HOST=unix:///run/podman-ci/podman.sock` in the runner container.
Restrict socket ownership and mode to the runner group.

Nested cgroup delegation is often unavailable inside a user-namespaced Pod. A
runtime-only implementation can disable inner cgroups in `containers.conf` and
let the outer Pod resource limits constrain the aggregate stack:

```toml
[containers]
cgroups = "disabled"
pids_limit = 0

[engine]
cgroup_manager = "cgroupfs"
events_logger = "file"
runtime = "crun"
```

Use overlay storage in an ephemeral graph volume:

```toml
[storage]
driver = "overlay"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"
```

Podman normally schedules container health checks using systemd timers. A
minimal sidecar has no systemd, so Compose `depends_on.condition:
service_healthy` may never progress unless the service process explicitly
drives health checks. A simple implementation periodically runs:

```sh
for id in $(podman ps -q 2>/dev/null); do
  podman healthcheck run "$id" >/dev/null 2>&1 || true
done
```

Treat this loop as lifecycle plumbing, not test logic. It must stop when the
Podman service exits.

## Why builds stay elsewhere

The Docker compatibility API is sufficient for `pull`, `run`, `exec`, `cp`,
and Compose lifecycle operations. It is not a drop-in BuildKit session
endpoint. Set `DOCKER_BUILDKIT=0` only for small compatibility probes; do not
move production compilation or multi-platform image builds to classic Podman.

The recommended pipeline is:

```text
BuildKit pool
  build once -> scan -> sign -> verify -> export repository@sha256 digest

Compose pool
  pull exact digest -> start services -> run tests -> collect evidence -> down -v
```

Test-runner images that are not release artifacts may remain unsigned if the
workflow passes them only by immutable digest from the same trusted build. Be
explicit that digest identity provides immutability, not provenance or signer
authentication.

## Job lifecycle contract

Every runtime wrapper should own its complete lifecycle:

1. Reject mutable references for every application, test-runner, and supporting
   runtime image.
2. Verify the workflow UID is non-root.
3. Reject an unexpected Kubernetes service-account token.
4. Verify `/proc/self/uid_map` shows a mapped range rather than host UID 0.
5. Create a run-qualified Compose project and network name.
6. Create a temporary Docker config, authenticate, and pull exact images.
7. Render `docker compose config` and compare resolved images with expected
   digests before startup.
8. Start only prebuilt services with `--no-build --wait`.
9. Run tests in a named container so reports can be copied after failure.
10. On every exit path, remove registry credential material before network or
    engine cleanup, capture logs and state, remove the named test container,
    and execute a time-bounded `down --volumes --remove-orphans`.
11. Record before/after container, volume, network, and disk state, then fail a
    previously successful job if teardown failed or residue remains.
12. Delete the remaining temporary Docker config directory.

Use a script-owned watchdog and signal handler. The handler should terminate
the active CLI process, force-remove the known test container after a short
grace period, and run bounded teardown. Treat cleanup as a correctness gate: a
green test must become a failed job when teardown fails or state remains.
CI-platform timeout behavior is not a substitute unless cancellation-to-signal
and cleanup semantics have been proven for the exact runner version.

## Horizontal scaling and sizing

Do not increase concurrency inside one Podman engine first. Deploy more
capacity-one runner Pods. This preserves cleanup isolation, makes failures
attributable to one job, and allows Kubernetes to spread engines across nodes.

Size from measurements rather than image metadata or build-runner limits:

- peak and p95 working-set bytes for the runner and Podman containers;
- peak CPU by container during cold pulls, service startup, and browsers;
- ephemeral graph-store and workspace high-water marks;
- job startup delay and execution duration;
- image-pull time split by warm and cold engine;
- OOM kills, evictions, and throttling;
- idle resource cost when `minRunners` is non-zero.

Requests should represent schedulable steady demand; limits should preserve
headroom for cold browser and database startup. Start conservatively, run cold
and concurrent workloads, then reduce requests only after observing multiple
representative runs. Use topology spread constraints or ARC scheduling rules
to avoid concentrating all engines on one node.

## Sanitized Kubernetes Pod template

The following fragment shows the security and volume relationships. It omits
registration, image pull secrets, NetworkPolicy, probes, and organization
policy. Pin every image by digest in a real deployment.

```yaml
spec:
  hostUsers: false
  hostNetwork: false
  hostPID: false
  hostIPC: false
  automountServiceAccountToken: false
  serviceAccountName: compose-runner
  securityContext:
    fsGroup: 1001
    fsGroupChangePolicy: OnRootMismatch
  containers:
    - name: runner
      image: registry.example/ci/runner@sha256:<digest>
      env:
        - name: DOCKER_HOST
          value: unix:///run/podman-ci/podman.sock
        - name: DOCKER_CONFIG
          value: /home/runner/.docker
        - name: DOCKER_BUILDKIT
          value: "0"
      securityContext:
        runAsNonRoot: true
        runAsUser: 1001
        runAsGroup: 1001
        allowPrivilegeEscalation: false
        capabilities: { drop: ["ALL"] }
        seccompProfile: { type: RuntimeDefault }
      volumeMounts:
        - { name: workspace, mountPath: /work }
        - { name: socket, mountPath: /run/podman-ci }
    - name: podman
      image: registry.example/ci/podman@sha256:<digest>
      command: ["/bin/sh", "-ceu"]
      args:
        - |
          install -d -m 0770 -o root -g 1001 /run/podman-ci
          rm -f /run/podman-ci/podman.sock
          podman system service --time=0 \
            unix:///run/podman-ci/podman.sock &
          service_pid=$!
          for attempt in $(seq 1 120); do
            if [ -S /run/podman-ci/podman.sock ]; then
              chown root:1001 /run/podman-ci/podman.sock
              chmod 0660 /run/podman-ci/podman.sock
              while kill -0 "$service_pid" 2>/dev/null; do
                for id in $(podman ps -q 2>/dev/null); do
                  podman healthcheck run "$id" >/dev/null 2>&1 || true
                done
                sleep 2
              done &
              wait "$service_pid"
              exit $?
            fi
            sleep 1
          done
          kill "$service_pid" 2>/dev/null || true
          echo "Podman API socket was not created" >&2
          exit 1
      securityContext:
        privileged: false
        runAsUser: 0
        runAsGroup: 0
        allowPrivilegeEscalation: true
        capabilities:
          add: ["SYS_ADMIN", "NET_ADMIN", "SYS_PTRACE"]
        seccompProfile: { type: Unconfined }
        appArmorProfile: { type: Unconfined }
        procMount: Unmasked
      volumeMounts:
        - { name: workspace, mountPath: /work }
        - { name: socket, mountPath: /run/podman-ci }
        - { name: graph, mountPath: /var/lib/containers }
        - { name: podman-config, mountPath: /etc/containers, readOnly: true }
  volumes:
    - name: workspace
      emptyDir: { sizeLimit: 10Gi }
    - name: socket
      emptyDir: { sizeLimit: 64Mi }
    - name: graph
      emptyDir: { sizeLimit: 30Gi }
    - name: podman-config
      configMap: { name: compose-runner-podman-config }
```

Add startup and readiness probes that query the service through the shared
socket. Production startup code should also forward termination to the service
and reap the health-check loop; the fragment focuses on the compatibility
contract.

## Gitea Actions deployment

A fixed Gitea pool can use a Deployment with one engine per replica:

- runner configuration capacity: one;
- a repository-scoped label such as `compose-runtime:host`;
- a unique runner name derived from the Pod hostname;
- four replicas only if four simultaneous engines are actually desired;
- topology spread across eligible nodes;
- `emptyDir` state, workspace, socket, and graph volumes;
- no generic `ubuntu-latest`-style label.

The runner executes jobs in host mode inside its own container. Workflow steps
use Docker CLI/Compose against the sidecar socket. Keep the control-plane
registration secret in a Kubernetes Secret, and keep registry credentials in
repository Actions secrets injected only into trusted jobs.

## GitHub Actions Runner Controller deployment

For GitHub, the same engine contract belongs in a dedicated Actions Runner
Controller runner scale set. ARC manages registration, ephemeral runner Pods,
and autoscaling; the custom Pod template supplies the runner tooling, shared
workspace, Podman sidecar, and security boundary.

GitHub's current ARC documentation supports repository, organization, and
enterprise destinations through `githubConfigUrl`, uses `runnerScaleSetName`
as the `runs-on` target, and allows the runner PodSpec under `template.spec`.
The runner container must be named `runner`. See
[Deploying runner scale sets](https://docs.github.com/en/actions/how-tos/manage-runners/use-actions-runner-controller/deploy-runner-scale-sets).

### Do not select a built-in container mode

Leave `containerMode` unset and provide the complete custom `template`. ARC's
built-in modes have different boundaries:

- `dind` injects Docker-in-Docker and requires privileged mode;
- `kubernetes` uses runner container hooks and Kubernetes API permissions to
  create job Pods.

The Podman sidecar pattern needs neither. It runs non-container-job workflow
steps in the runner container and exposes a private Docker-compatible API to
those steps. GitHub notes that fully customized PodSpecs or container modes may
fall outside normal support scope, so test chart and runner upgrades in a
production-like staging cluster.

### Sanitized ARC values skeleton

This skeleton is an implementation starting point, not a complete install. It
assumes an organization-managed runner image containing the GitHub runner,
Docker CLI, Compose plugin, a `timeout` utility for bounded teardown, and
workflow tools. Pin images by digest and add the Podman config, probes,
health-check driver, resource settings, scheduling, NetworkPolicy, and
admission-policy exceptions validated for your cluster.

```yaml
githubConfigUrl: https://github.com/example-org
githubConfigSecret: arc-github-app
runnerGroup: compose-runtime
runnerScaleSetName: compose-runtime-linux

minRunners: 0
maxRunners: 20

# Intentionally no containerMode. This is a custom sidecar mode.
template:
  spec:
    hostUsers: false
    hostNetwork: false
    hostPID: false
    hostIPC: false
    automountServiceAccountToken: false
    serviceAccountName: compose-runner
    securityContext:
      fsGroup: 1001
      fsGroupChangePolicy: OnRootMismatch
    containers:
      - name: runner
        image: registry.example/ci/actions-runner@sha256:<digest>
        command: ["/home/runner/run.sh"]
        env:
          - name: DOCKER_HOST
            value: unix:///run/podman-ci/podman.sock
          - name: DOCKER_CONFIG
            value: /home/runner/.docker
          - name: DOCKER_BUILDKIT
            value: "0"
        securityContext:
          runAsNonRoot: true
          runAsUser: 1001
          runAsGroup: 1001
          allowPrivilegeEscalation: false
          capabilities: { drop: ["ALL"] }
          seccompProfile: { type: RuntimeDefault }
        volumeMounts:
          # Keep the normal Actions checkout path identical in both containers.
          - { name: work, mountPath: /home/runner/_work }
          - { name: socket, mountPath: /run/podman-ci }
      - name: podman
        image: registry.example/ci/podman@sha256:<digest>
        command: ["/usr/local/bin/start-podman-ci"]
        securityContext:
          privileged: false
          runAsUser: 0
          runAsGroup: 0
          allowPrivilegeEscalation: true
          capabilities:
            add: ["SYS_ADMIN", "NET_ADMIN", "SYS_PTRACE"]
          seccompProfile: { type: Unconfined }
          appArmorProfile: { type: Unconfined }
          procMount: Unmasked
        volumeMounts:
          - { name: work, mountPath: /home/runner/_work }
          - { name: socket, mountPath: /run/podman-ci }
          - { name: graph, mountPath: /var/lib/containers }
          - { name: podman-config, mountPath: /etc/containers, readOnly: true }
    volumes:
      - name: work
        emptyDir: { sizeLimit: 10Gi }
      - name: socket
        emptyDir: { sizeLimit: 64Mi }
      - name: graph
        emptyDir: { sizeLimit: 30Gi }
      - name: podman-config
        configMap: { name: compose-runner-podman-config }
```

Use a GitHub App credential referenced by `githubConfigSecret` rather than
embedding it in values when the selected repository or organization scope
supports GitHub App authentication; follow GitHub's current authentication
guidance for enterprise-level destinations. Restrict access with a runner group
and repository or organization destination. ARC can keep `minRunners: 0` for
fully ephemeral capacity or retain a small warm pool when cold image pulls
dominate latency.

### ARC-specific operational guidance

- Expose ARC controller and listener metrics to Prometheus. GitHub documents
  runner counts plus job startup and execution duration metrics; combine them
  with kubelet container CPU, memory, and filesystem metrics.
- Keep this runtime scale set separate from rootless BuildKit scale sets. They
  need different capabilities, caches, resource shapes, and trust policies.
- Install runner scale sets in a namespace separate from the ARC controller
  namespace, following GitHub's deployment guidance.
- Use runner groups and workflow permissions so fork pull requests and
  untrusted automation cannot select the runtime label or receive private
  registry credentials.
- Prefer ephemeral Pods (`minRunners: 0`) when isolation matters more than warm
  image caches. Use a small minimum only after measuring pull cost and idle
  resource consumption.
- Set topology spread, node affinity, taints/tolerations, and priority classes
  in `template.spec` according to enterprise cluster policy.
- Mirror and pin controller, listener, runner, Podman, and helper images in an
  approved registry.
- Test ARC chart upgrades against this custom PodSpec. Do not assume injected
  volumes, environment variables, or container merging remain compatible.
- If an enterprise policy forbids the Podman container's namespaced
  capabilities or unconfined profiles, choose a dedicated VM runner pool rather
  than weakening node isolation.

## Platform mapping

| Concern | Fixed Gitea pool | GitHub ARC scale set |
| --- | --- | --- |
| Registration | long-running runner Deployment | ARC-managed ephemeral registration |
| Scaling | Deployment replicas | `minRunners` / `maxRunners` |
| Job selector | repository-scoped label | `runnerScaleSetName` and runner group |
| Engine lifetime | Pod lifetime, reused across jobs | normally one ephemeral runner Pod |
| Warm images | retained until Pod replacement | retained only in warm/idle Pods |
| Kubernetes API | token disabled | token disabled for custom sidecar mode |
| Build path | separate BuildKit label | separate BuildKit scale set |
| Compose API | private Podman Unix socket | same private Podman Unix socket |
| Workspace | configured host workdir | `/home/runner/_work` shared identically |
| Capacity | one job per runner replica | one job per ephemeral runner Pod |

## Implementation sequence

1. Prove Pod user namespaces on every eligible node and record the UID map.
2. Start Podman with the smallest required security context and verify the
   private socket from a non-root runner container.
3. Prove pull, run, exec, copy, DNS, health checks, bind mounts, and teardown
   with a two-service Compose fixture.
4. Run the exact application Compose topology and a focused browser or
   integration test without publishing credentials.
5. Add signal handling, watchdog behavior, artifacts, and residue checks.
6. Register one capacity-one CI runner and repeat the canary after Pod
   replacement.
7. Move one runtime lane at a time. Keep image builds on BuildKit and compare
   semantics, digest identity, cleanup, and timing before removing the previous
   runtime.
8. Add replicas or ARC autoscaling only after observing cold and concurrent
   resource peaks.
9. Exercise node loss, Pod eviction, runner cancellation, registry failure,
   and partial Compose startup.
10. Document the remaining Kubernetes release gate so Compose success is not
    mistaken for chart or upgrade validation.

## Acceptance checklist

- [ ] Runner process is non-root.
- [ ] Pod has a non-host UID map and `hostUsers: false`.
- [ ] No privileged container, `hostPath`, host runtime socket, host namespace,
      explicit host device, or Kubernetes token exists.
- [ ] Podman API is a private Unix socket with restricted group permissions.
- [ ] Workspace paths are identical in the runner and engine containers.
- [ ] Compose health checks progress without systemd.
- [ ] Every application, test, database, search, and helper image resolves to an
      expected immutable digest.
- [ ] Runtime jobs perform no application compilation or image build.
- [ ] Success, failure, timeout, and termination paths all reach bounded
      teardown.
- [ ] Post-job state is zero containers, zero volumes, and zero project
      networks.
- [ ] Cold, warm, and concurrent resource peaks fit requests, limits, node
      headroom, and ephemeral-storage budgets.
- [ ] Untrusted workflows cannot select the pool or receive its credentials.
- [ ] Kubernetes deployment/release validation remains separately enforced.
- [ ] Runner and controller upgrades are canaried before production rollout.

## When to choose a VM instead

Use dedicated VM runners when the cluster cannot provide Pod user namespaces,
admission policy forbids the required namespaced capabilities, node security
modules cannot support the Podman service consistently, or the CI platform
does not tolerate a custom runner PodSpec. A rootless Podman or Docker service
on a dedicated VM is operationally simpler and gives a clearer fault boundary
than progressively weakening a Kubernetes Pod until nested containers work.
