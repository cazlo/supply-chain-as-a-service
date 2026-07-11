# Cargo mTLS Upstream Research

This document records the current upstream state of mutual TLS (mTLS) client
authentication for Rust's Cargo package manager and recommends where to
contribute. It follows the broader ecosystem survey in
[Package Manager mTLS Support](package-manager-mtls-support.md).

The research was last verified on 2026-07-10.

## Recommendation

Do not open another Cargo implementation pull request yet.

The feature request is already in Cargo's required design process:

- [rust-lang/cargo#10641](https://github.com/rust-lang/cargo/issues/10641) is the
  canonical open feature request. It is labeled `S-needs-rfc`, not
  `S-accepted`.
- [rust-lang/rfcs#3907](https://github.com/rust-lang/rfcs/pull/3907), **Cargo
  mTLS registry authentication**, is an active RFC authored by Matt Hague. It
  was opened on 2026-01-17 and remains open with the `T-cargo` label.
- Two direct implementation attempts were closed because the design had not
  first been accepted:
  [rust-lang/cargo#10630](https://github.com/rust-lang/cargo/pull/10630) in 2022
  and [rust-lang/cargo#16260](https://github.com/rust-lang/cargo/pull/16260) in
  2025.

The useful contribution now is to help RFC 3907 answer its remaining security,
scope, and lifecycle questions. The enterprise Artifact Keeper and Teleport
use case provides concrete evidence that the feature is needed, and short-lived
Teleport identities expose design requirements that the RFC does not yet fully
address.

Fork [rust-lang/cargo](https://github.com/rust-lang/cargo) when the RFC is
accepted and the Cargo issue is marked accepted, or earlier only for a private
prototype. Do not submit that prototype as a feature PR while the issue remains
`S-needs-rfc`.

## Upstream history and status

| Upstream item | Status on 2026-07-10 | Significance |
| --- | --- | --- |
| [cargo#10641: Add client certificates option to cargo registries](https://github.com/rust-lang/cargo/issues/10641) | Open; `S-needs-rfc` | Canonical tracking and motivation issue. Continue using this issue rather than opening a duplicate. |
| [rfcs#3907: Cargo mTLS registry authentication](https://github.com/rust-lang/rfcs/pull/3907) | Open; `T-cargo`; no final-comment period visible | Current design proposal and primary place for substantive design feedback. |
| [cargo#10630: Add client certificates option to cargo](https://github.com/rust-lang/cargo/pull/10630) | Closed, not merged, 2022-10-01 | A direct `config.toml` and libcurl implementation. Maintainers concluded registry authentication needed design work and likely an RFC. |
| [cargo#16260: Mutual TLS support for authentication with registry](https://github.com/rust-lang/cargo/pull/16260) | Closed, not merged, 2025-11-18 | A newer direct certificate/key configuration attempt. It was closed because Cargo only reviews accepted features and this one requires an RFC. |
| [cargo#16236](https://github.com/rust-lang/cargo/issues/16236) | Closed as duplicate | Confirms that #10641 remains the canonical Cargo issue. |

Cargo's [contributor guide](https://doc.crates.io/contrib/process/working-on-cargo.html#before-hacking-on-cargo)
asks contributors to discuss feature designs before implementation and states
that only explicitly accepted issues will be reviewed. The
[Rust RFC process](https://github.com/rust-lang/rfcs#what-the-process-is) says
implementation begins after an RFC is merged and active. The two closed Cargo
PRs show that maintainers are applying that policy to this feature.

## What RFC 3907 proposes

The RFC does not put certificate paths or private-key passwords directly in
Cargo configuration. Instead, it extends the existing
[Cargo Credential Provider Protocol](https://doc.rust-lang.org/cargo/reference/credential-provider-protocol.html)
from version 1 to version 2:

1. Cargo sends a `tls-identity` request containing registry information and
   credential-provider arguments.
2. The provider returns a PEM certificate chain and PEM private key.
3. Cargo retains the response in memory for use with that registry during the
   current Cargo session.
4. Cargo must not persist, print, or log either blob.
5. Providers must decrypt encrypted keys before returning them. The proposed
   Cargo response format itself does not support encrypted private keys.

The proposed libcurl implementation uses in-memory
[`CURLOPT_SSLCERT_BLOB`](https://curl.se/libcurl/c/CURLOPT_SSLCERT_BLOB.html)
and
[`CURLOPT_SSLKEY_BLOB`](https://curl.se/libcurl/c/CURLOPT_SSLKEY_BLOB.html)
rather than passing file paths to libcurl. This lets a provider read files
written by `tbot`, obtain material from another credential store, or perform
other organization-specific work without teaching Cargo every secret-storage
scheme.

This direction is preferable to the old direct-config proposals because it:

- keeps secret acquisition in Cargo's existing credential-provider trust
  boundary;
- avoids placing a private-key password in `.cargo/config.toml`;
- allows a provider to combine separate `tbot` certificate and key outputs into
  the response format;
- passes identities in memory to the HTTP backend; and
- does not make file paths part of a public interface that a future non-libcurl
  backend would have to emulate.

## Best contributions before implementation

Start by reading RFC 3907 and its inline review threads, then post a focused
comment on the RFC rather than a new proposal. The existing
[Cargo Zulip mTLS discussion](https://rust-lang.zulipchat.com/#narrow/channel/246057-t-cargo/topic/Mutual.20TLS.20ideas/with/560026001)
is the right place for higher-bandwidth design discussion.

The most useful material to contribute is:

### Concrete enterprise motivation

Describe the actual architecture:

- Artifact Keeper exposes a private Cargo registry through Teleport Application
  Access.
- `tbot` issues and renews short-lived, separate PEM certificate and key files.
- Cargo may still send a registry token for repository-level authorization;
  mTLS is the outer workload or user identity and is not necessarily a
  replacement for application authorization.
- A local Teleport application tunnel is a workaround, but native support avoids
  a continuously running local proxy and preserves direct client identity.

Link the ecosystem evidence in
[Package Manager mTLS Support](package-manager-mtls-support.md) rather than
copying the entire survey into an RFC comment.

### Exact credential scope

“Registry-scoped” is not yet precise enough for safe certificate presentation.
One Cargo registry can involve several network destinations:

- the sparse index URL;
- the crate download URL supplied by the registry's `config.json`;
- the registry API URL used for publish, yank, owner, and search operations; and
- redirect targets or a content-delivery network.

The RFC should define which HTTPS origins are authorized to receive an identity
and how an additional origin becomes authorized. It should not imply that every
host reached while processing one logical registry inherits the certificate.

This is distinct from bearer-token redirect handling. libcurl documents that it
limits `Authorization` and explicit `Cookie` headers when
[`CURLOPT_FOLLOWLOCATION`](https://curl.se/libcurl/c/CURLOPT_FOLLOWLOCATION.html)
crosses hosts, but that documentation does not promise equivalent origin
scoping for a TLS client certificate configured on the easy handle. The
implementation therefore needs an explicit policy and an end-to-end test rather
than relying on HTTP-header behavior.

Possible policies to discuss include:

- authorize only the canonical HTTPS origin in the credential request;
- require an explicit identity mapping for each index, download, and API origin;
- handle redirects in Cargo so identity selection is re-evaluated for every
  origin; or
- reject cross-origin redirects for requests carrying a client identity.

### Rotation and caching

The RFC says the identity is used for the current Cargo session, but its response
has no expiry or refresh signal. This matters for `tbot` because its certificates
are deliberately short-lived and may rotate during a long Cargo process or
daemon-like use.

Ask the RFC to specify:

- when Cargo calls `tls-identity` again;
- whether the existing credential cache-control model applies;
- what happens when a certificate expires during a session;
- whether a new connection picks up rotated material; and
- how old key bytes and libcurl handle state are discarded.

Refreshing for every request is simple but may make an external provider
expensive. Caching for the entire process is efficient but can retain expired
credentials. An explicit expiry or cache-control response would make the policy
testable.

### Protocol behavior

Current review discussion also asks for clarity on:

- what `args` means in a `tls-identity` request;
- whether “no identity” is represented by empty fields or an error such as
  `not-found`;
- how provider fallback works when several providers are configured;
- whether PEM is the best portable interchange format for a future Rust-native
  TLS backend; and
- guidance for registries using tokens, mTLS, or both.

It would be valuable to test the proposed version-2 exchange with a small
credential-provider prototype before the RFC is finalized. That prototype does
not require a public Cargo feature PR.

### TLS backend compatibility

The RFC's proposed pair of PEM blobs does not map uniformly to Cargo's supported
libcurl backends. libcurl documents that `CURLOPT_SSLCERT_BLOB` requires PKCS#12
on Schannel, while `CURLOPT_SSLKEY_BLOB` is supported only by OpenSSL and
wolfSSL. Cargo's own source notes that its Windows libcurl is usually built with
[Schannel](https://github.com/rust-lang/cargo/blob/0a28f7930c7b559c37fc221347114f9c6434f2ae/src/cargo/util/network/http.rs#L148).

As drafted, separate PEM certificate and key fields therefore do not provide an
obvious Windows implementation. The RFC should either define a portable
identity representation and conversion responsibility, document an intentional
platform limitation, or choose backend-specific handling behind a
backend-neutral protocol. This is worth raising before the protocol-v2 wire
format becomes stable.

## Draft RFC comments

Five focused comments, each in Drew's first-person upstream voice. Post them in
order: comments 3 and 4 refer back to the Go proof of concept introduced in
comment 1. Each fenced block is the paste-ready body; the text around it is
placement guidance only.

The Go work must always be described as a proof of concept: an implementation
POC attached to the open Go proposal
[golang/go#30119](https://github.com/golang/go/issues/30119), submitted as
[golang/go#80371](https://github.com/golang/go/pull/80371)
([CL 799701](https://go-review.googlesource.com/c/go/+/799701)) toward a future
Go release. It is not merged and the proposal is not accepted.

Before posting, coordinate with the RFC author in the existing Zulip thread.
Avoid proposing a second RFC unless the Cargo team or the current author
explicitly asks for one.

### Comment 1: use case and rotation/expiry (top-level PR comment)

Post as a top-level comment on
[rust-lang/rfcs#3907](https://github.com/rust-lang/rfcs/pull/3907).

```markdown
I have a concrete production use case for this RFC: a private Cargo registry
served through Teleport Application Access. Teleport's `tbot` agent writes a
short-lived PEM client certificate and key to disk and renews them
automatically before expiry. The registry continues to use a token for
repository-level authorization, so mTLS and the existing token flow need to
coexist. This shape is not Teleport-specific. SPIFFE's `spiffe-helper` and
Vault Agent's PKI templates produce the same rotating PEM certificate and key
files, so the credential-provider design here fits the broader
workload-identity ecosystem well: a small provider just reads the current
files.

Short-lived identities expose one gap in the current draft: the identity is
"used for subsequent communication to the same registry (within the current
Cargo session)", but the response carries no expiry or refresh signal. A
`tbot`-issued certificate can expire in the middle of a large fetch or a
long-running invocation. Could the `tls-identity` response reuse the existing
`CacheControl` model from the token `get` response (`"cache":"never"`,
`"cache":"session"`, or `"cache":"expires"` with a sibling `"expiration"` unix
timestamp)? That would make the refresh policy explicit and testable: Cargo
uses the cached identity until `expiration`, and the first time it needs a new
connection after that, it sends a fresh `tls-identity` request instead of
handshaking with a stale certificate.

For prior art: I recently built a proof-of-concept implementation of the
equivalent feature for Go's open proposal golang/go#30119 (golang/go#80371,
https://go-review.googlesource.com/c/go/+/799701). It adds an origin-scoped
`GOAUTH=mtls` method aimed at the same style of deployment, targeting a future
Go release. Client certificates for native registry traffic are already
supported by npm, Yarn, pnpm, pip, uv, Maven, Gradle, NuGet, Composer,
Bundler, and Conan.

I'm happy to build a prototype credential provider against the v2 protocol and
help test the rotation and scoping cases.
```

### Comment 2: empty fields vs `not-found` (reply to Eh2406)

Post as a reply in the existing thread
[rust-lang/rfcs#3907 discussion r2705502777](https://github.com/rust-lang/rfcs/pull/3907#discussion_r2705502777),
where Eh2406 asks when a provider should return empty fields versus
`"Err":{"kind":"not-found"}`.

```markdown
One data point from how the token path handles this today: Cargo's provider
chain treats `url-not-supported` and `not-found` as fall-through and tries the
next configured provider, and only errors if no provider produced a result. If
"no identity" is represented by empty fields in an `Ok` response, a
multi-provider configuration behaves differently for identities than for
tokens: the chain stops at the first provider even though it had nothing.

I'd suggest `not-found` for "this provider has no identity for this
registry/origin", `url-not-supported` for "this provider doesn't handle this
registry at all", and treating empty `certificate`/`key` fields in an `Ok`
response as a protocol error. That keeps fallback semantics identical across
request kinds, which also matters for mixed deployments where one provider
serves tokens and a different one serves TLS identities.
```

### Comment 3: authorized-origin scope (inline review comment)

Anchor on the guide-level sentence "the returned identity will be used for
subsequent communication to the same registry (within the current Cargo
session)".

```markdown
"The same registry" can involve several HTTPS origins: the sparse index URL,
the `dl` URL from the registry's `config.json` (often a CDN on a different
host), and the API URL used for publish, yank, owner, and search. I think the
RFC should define which origins are authorized to receive the identity,
because the default behavior of the current implementation surface would be
broader than any of them: on current master (0a28f7930c), registry traffic
goes through the shared `http_async` client, and every request handle sets
`follow_location(true)`, so libcurl follows redirects internally. A
certificate configured on that handle is presented to every redirect hop,
including cross-origin ones. libcurl's documented cross-host protections for
`Authorization` headers do not cover TLS client certificates, which are
selected at handshake time.

Note that Cargo's token behavior already faces this question: with
`auth-required`, the Authorization header is sent to whatever origin the `dl`
template resolves to. I think the identity design should be stricter than that
precedent, since a certificate is presented at handshake time to every
connection made by the handle rather than attached to individual requests.

There is a second isolation question in the same place: all easy handles share
one curl multi and its connection cache. With two registries using different
identities in one invocation, connection reuse and HTTP/2 multiplexing must
never match a connection that was established under a different client
certificate. curl has had this bug class twice: CVE-2021-22924 (connection
reuse matched despite differing certificate-related config) and CVE-2022-27782
(TLS settings omitted from the reuse check entirely, fixed in 7.83.1). The
second matters here because Cargo often links a system libcurl older than the
fix, so it seems worth an explicit test rather than an assumption.

In the Go proof of concept linked above I scoped the certificate to one
canonical HTTPS origin, used a distinct transport per identity so pooling
cannot cross identity boundaries, and re-evaluated selection on every redirect
hop. For Cargo the options seem to be: authorize only explicitly mapped
origins, re-evaluate identity per hop by handling redirects in Cargo itself,
or reject cross-origin redirects while an identity is loaded. Any of those can
work; I mainly think the RFC text should pick one rather than leave it to the
implementation.
```

### Comment 4: TLS backend portability of the wire format (inline review comment)

Anchor on the "Certificate and key formats" section.

```markdown
In the Zulip thread the question came up whether HSM support via `ssl_engine`
would lock Cargo into curl/OpenSSL. The same backend portability concern
already applies to this response format on stock Windows builds today: Cargo's
Windows libcurl is usually built with Schannel (see the comment in
`src/cargo/util/network/http.rs`), and libcurl documents that
`CURLOPT_SSLCERT_BLOB` under Schannel requires PKCS#12, while
`CURLOPT_SSLKEY_BLOB` is supported only by OpenSSL and wolfSSL. As drafted,
the separate PEM certificate and key fields have no obvious implementation
path on the default Windows toolchain.

I think the RFC should pick one of: (a) Cargo converts the PEM pair in memory
to whatever the backend needs (PEM to PKCS#12 for Schannel); (b) an
intentional, documented platform limitation with a clear fail-closed error,
since silently continuing without client authentication would be the worst
outcome; or (c) a format field negotiated per backend behind the protocol.

Related: since a signing-oracle flow (the provider signs a digest and the key
never leaves an HSM) is the likely future answer to the TPM/smartcard
discussion above, it may be worth wording the response so that `key` is not
structurally mandatory forever, for example "exactly one of `key` or a future
signing capability", so protocol v2 can grow that without a breaking change.
```

### Comment 5: tokens vs mTLS vs both (reply to Eh2406)

Post as a reply in the existing thread
[rust-lang/rfcs#3907 discussion r2705541671](https://github.com/rust-lang/rfcs/pull/3907#discussion_r2705541671),
where Eh2406 asks what guidance registries should get on tokens, mTLS, or
both.

```markdown
One operator data point: in my deployment they answer different questions and
coexist. mTLS is the network-layer control: an identity-aware proxy (Teleport
in my case, but Cloudflare Access or plain nginx `ssl_verify_client` are the
same shape) decides whether the workload may reach the registry at all, before
any HTTP request is made. The registry token remains the application-layer
control: which repositories, read versus publish. Suggested guidance along
those lines: mTLS authenticates the connection or workload, tokens authorize
registry operations; a registry deployed behind an identity-aware proxy
typically needs both, while a registry that terminates TLS itself and maps
certificates to accounts may use mTLS alone. The deciding factor is whether
the system checking the certificate and the system checking authorization are
the same one.
```

### Held in reserve: `Secret` typing for the key field

Do not post this with the initial batch — five comments plus a top-level from a
new participant is the healthy limit, and this one reads best as a follow-up
once the author re-engages. Anchor on the "Security Considerations" section.

```markdown
A small implementation note on "Cargo MUST NOT log, print, or otherwise expose
the contents of these blobs, including in debug or trace output": as written
this is unenforceable by review alone, because Cargo currently logs every
credential-provider response through its `Debug` implementation at debug level
(`src/cargo/util/credential/process.rs`). The `cargo-credential` crate already
has the fix: the `Secret<T>` wrapper serializes transparently but redacts
`Debug`, which is how the token field is protected today. If the RFC specifies
that the `key` field (and arguably `certificate` too) is typed `Secret<String>`
in the protocol crate, the MUST NOT holds by construction rather than by
convention.
```

## Where to fork

### Now: usually no fork is needed

GitHub comments and Zulip discussion are sufficient for design feedback. If the
RFC author wants help editing RFC 3907, coordinate first. Because the open RFC
branch belongs to `matthague/rfcs`, the cleanest collaboration mechanism may be
a commit or pull request against that branch, depending on the author's
preference. Do not open a competing PR against `rust-lang/rfcs` for the same
design.

### For a private spike

Fork [rust-lang/cargo](https://github.com/rust-lang/cargo) to a personal GitHub
account and keep the work as an exploratory branch. A conventional setup is:

```sh
gh repo fork rust-lang/cargo --clone
cd cargo
git remote add upstream https://github.com/rust-lang/cargo.git
git fetch upstream
git switch -c mtls-prototype upstream/master
```

`gh repo fork --clone` may already configure an `upstream` remote. Check
`git remote -v` before adding it and skip the `git remote add` command when it is
already present.

Use the spike to validate uncertain protocol and transport behavior, not to
bypass the acceptance gate. Sharing experimental results in the RFC is more
useful than asking maintainers to review an unaccepted implementation.

### After the design is accepted

Use the same Cargo fork, update from `upstream/master`, and create a fresh
implementation branch. Cargo uses the fork-and-pull model and targets its
`master` branch, as documented in
[Working on Cargo](https://doc.crates.io/contrib/process/working-on-cargo.html#checkout-the-source).

```sh
git fetch upstream
git switch -c mtls-registry-authentication upstream/master
cargo build
```

Nightly Rust is recommended by the contributor guide because some tests are
disabled on stable, although Cargo is expected to build with stable, beta, and
nightly. Unix builds also require a C compiler, Git, `pkg-config`, and OpenSSL
development files.

## Likely implementation surface

The following map is based on Cargo commit
[`0a28f7930c7b559c37fc221347114f9c6434f2ae`](https://github.com/rust-lang/cargo/commit/0a28f7930c7b559c37fc221347114f9c6434f2ae)
from 2026-07-10. Paths will move, so re-check `master` after the RFC is accepted.

| Area | Current code | Likely work |
| --- | --- | --- |
| Credential protocol types | [`credential/cargo-credential/src/lib.rs`](https://github.com/rust-lang/cargo/blob/0a28f7930c7b559c37fc221347114f9c6434f2ae/credential/cargo-credential/src/lib.rs#L81) | Add protocol-v2 negotiation and typed `tls-identity` request/response without breaking v1 providers. |
| Provider invocation and fallback | [`src/cargo/util/credential/process.rs`](https://github.com/rust-lang/cargo/blob/0a28f7930c7b559c37fc221347114f9c6434f2ae/src/cargo/util/credential/process.rs#L36) and [`src/cargo/util/auth/mod.rs`](https://github.com/rust-lang/cargo/blob/0a28f7930c7b559c37fc221347114f9c6434f2ae/src/cargo/util/auth/mod.rs#L558) | Request an identity for the intended registry, define v1 fallback, cache it safely, and preserve provider-chain semantics. |
| HTTP handle configuration | [`src/cargo/util/network/http.rs`](https://github.com/rust-lang/cargo/blob/0a28f7930c7b559c37fc221347114f9c6434f2ae/src/cargo/util/network/http.rs#L48) | Apply the selected in-memory certificate and key to an appropriate easy handle without turning identity into global HTTP configuration. |
| Async HTTP client | [`src/cargo/util/network/http_async.rs`](https://github.com/rust-lang/cargo/blob/0a28f7930c7b559c37fc221347114f9c6434f2ae/src/cargo/util/network/http_async.rs#L73) | The shared client creates easy handles and follows redirects. It needs per-request or per-authorized-origin identity selection that remains safe with pooling and multiplexing. |
| Shared HTTP clients | [`src/cargo/util/context/mod.rs`](https://github.com/rust-lang/cargo/blob/0a28f7930c7b559c37fc221347114f9c6434f2ae/src/cargo/util/context/mod.rs#L1923) | Avoid leaving one registry's identity on a reusable global handle. Reset and connection-cache behavior need scrutiny. |
| Sparse registry index | [`src/cargo/sources/registry/http_remote.rs`](https://github.com/rust-lang/cargo/blob/0a28f7930c7b559c37fc221347114f9c6434f2ae/src/cargo/sources/registry/http_remote.rs#L338) | Associate index requests with a registry identity rather than only a URL string. |
| Crate downloads | [`src/cargo/sources/registry/download.rs`](https://github.com/rust-lang/cargo/blob/0a28f7930c7b559c37fc221347114f9c6434f2ae/src/cargo/sources/registry/download.rs#L29) | Decide whether and how the identity applies when `config.json` points `dl` at another origin. |
| User documentation | [`src/doc/src/reference/credential-provider-protocol.md`](https://github.com/rust-lang/cargo/blob/0a28f7930c7b559c37fc221347114f9c6434f2ae/src/doc/src/reference/credential-provider-protocol.md) and [`registry-authentication.md`](https://github.com/rust-lang/cargo/blob/0a28f7930c7b559c37fc221347114f9c6434f2ae/src/doc/src/reference/registry-authentication.md) | Document protocol v2, scoping, provider examples, token interaction, security, and backend limitations. |

The current HTTP configuration schema in
[`schema.rs`](https://github.com/rust-lang/cargo/blob/0a28f7930c7b559c37fc221347114f9c6434f2ae/src/cargo/util/context/schema.rs#L43)
contains proxy, CA, timeout, revocation, user-agent, multiplexing, and TLS-version
settings but no client identity. RFC 3907 intentionally avoids solving this by
adding global certificate paths there.

Git-index registries and Git dependencies are a separate transport boundary.
`net.git-fetch-with-cli` can delegate them to a Git client with its own mTLS
configuration, but that does not cover Cargo's sparse index, crate downloads, or
registry API. The RFC should avoid implying that a Cargo HTTP implementation
automatically configures every Git backend.

## Security review checklist

An implementation should not be considered complete until all of these are
specified and tested.

### Credential selection

- Require HTTPS before presenting a client identity.
- Select by a canonical, explicitly authorized origin or equally precise scope.
- Re-evaluate selection for redirects and registry-provided secondary URLs.
- Never send an identity merely because two URLs belong to one logical registry.
- Define behavior for default ports, URL normalization, aliases, and source
  replacement.

### Secret handling

- Do not persist certificate or key response data.
- Redact it from errors, `Debug`, trace output, process diagnostics, and test
  snapshots. The current credential-process path logs the response through its
  `Debug` implementation at debug level, so protocol types must use secret
  wrappers or custom redacted formatting.
- Avoid unnecessary copies; clear owned key buffers when practical.
- Ensure provider error messages cannot accidentally echo request or response
  secrets.

### HTTP isolation

- Do not leave an identity configured on Cargo's reusable global easy handle.
- Verify connection reuse, HTTP/2 multiplexing, and libcurl's connection cache
  do not cross identity boundaries.
- Test cross-origin redirects rather than assuming libcurl's bearer-header
  protections apply to TLS identities.
- Preserve normal server certificate and hostname verification.

An HTTPS proxy has a distinct TLS connection from the origin. libcurl exposes
separate
[`CURLOPT_PROXY_SSLCERT_BLOB`](https://curl.se/libcurl/c/CURLOPT_PROXY_SSLCERT_BLOB.html)
for a proxy client certificate. Cargo must apply a registry identity only as the
origin identity and must not reinterpret it as proxy authentication. Whether a
particular origin mTLS backend combination works through a CONNECT tunnel should
be covered by platform tests rather than by disabling verification.

### Portability

libcurl documents different support by TLS backend: certificate blobs accept
different formats across OpenSSL, Schannel, mbedTLS, and wolfSSL, while private
key blobs work only with OpenSSL and wolfSSL. In particular, Schannel requires a
PKCS#12 certificate blob rather than the separate PEM certificate and key in the
current RFC. Before stabilizing the feature, Cargo needs an intentional
compatibility story for the libcurl/TLS combinations it ships or supports.
Unsupported combinations should fail clearly, not silently continue without
client authentication.

## Minimum test plan

The previous implementation attempts did not establish a convincing end-to-end
testing strategy. RFC-level protocol tests and Cargo integration tests should
cover at least:

- credential protocol v1 compatibility and v2 negotiation;
- successful separate PEM certificate/key delivery;
- certificate-chain delivery;
- provider fallthrough for unsupported registry or no identity;
- provider failure, malformed PEM, mismatched key, and missing identity;
- sparse index access, `config.json`, and crate download;
- registry API operations such as publish or search where applicable;
- token-only, mTLS-only, and token-plus-mTLS registries;
- two private registries with different identities in one Cargo invocation;
- a private and public registry in one invocation, proving no identity leakage;
- same-origin and cross-origin redirects;
- a `dl` URL on the index origin and on a different origin;
- HTTPS proxy behavior;
- certificate rotation or expiry during a session;
- absence of PEM material from normal, verbose, debug, and trace output; and
- the supported libcurl TLS backends on Cargo's CI platforms.

Existing starting points include
[`tests/testsuite/credential_process.rs`](https://github.com/rust-lang/cargo/blob/0a28f7930c7b559c37fc221347114f9c6434f2ae/tests/testsuite/credential_process.rs),
[`tests/testsuite/registry_auth.rs`](https://github.com/rust-lang/cargo/blob/0a28f7930c7b559c37fc221347114f9c6434f2ae/tests/testsuite/registry_auth.rs),
and
[`tests/testsuite/https.rs`](https://github.com/rust-lang/cargo/blob/0a28f7930c7b559c37fc221347114f9c6434f2ae/tests/testsuite/https.rs).
The HTTPS suite currently focuses on server trust. Its container fixture or a
new purpose-built test server will need client-certificate verification.

Cargo's contributor guide requires tests for non-trivial code and recommends
putting tests in an atomic commit before the functionality change when that
history remains coherent. Follow the exact test commands documented in Cargo's
[testing guide](https://doc.crates.io/contrib/tests/index.html).

## Proposed sequence

1. Join the existing Zulip thread and introduce the Artifact Keeper plus
   Teleport use case.
2. Post the five drafted comments on RFC 3907 in order: use case plus
   expiry/refresh, `not-found` semantics, authorized-origin scope, TLS backend
   portability, and tokens-versus-mTLS guidance.
3. Offer the package-manager survey as prior-art evidence and help refine the
   RFC's security and testing sections.
4. If useful, build a private protocol/provider spike and report results without
   opening a Cargo feature PR.
5. Wait for the RFC to be merged and the Cargo feature to be accepted.
6. Coordinate implementation ownership with the RFC author and Cargo team so
   work is not duplicated.
7. Fork `rust-lang/cargo`, branch from current `upstream/master`, add end-to-end
   tests, implement the accepted design, and submit the PR against Cargo's
   `master` branch.

## Primary sources

- [Cargo mTLS feature issue](https://github.com/rust-lang/cargo/issues/10641)
- [Active Cargo mTLS RFC](https://github.com/rust-lang/rfcs/pull/3907)
- [Cargo contributor guide](https://doc.crates.io/contrib/process/working-on-cargo.html)
- [Cargo RFC guide](https://doc.crates.io/contrib/process/rfc.html)
- [Rust RFC process](https://github.com/rust-lang/rfcs)
- [Cargo credential provider protocol](https://doc.rust-lang.org/cargo/reference/credential-provider-protocol.html)
- [Cargo registry authentication](https://doc.rust-lang.org/cargo/reference/registry-authentication.html)
- [libcurl client-certificate blob option](https://curl.se/libcurl/c/CURLOPT_SSLCERT_BLOB.html)
- [libcurl private-key blob option](https://curl.se/libcurl/c/CURLOPT_SSLKEY_BLOB.html)
- [libcurl redirect behavior](https://curl.se/libcurl/c/CURLOPT_FOLLOWLOCATION.html)
- [Closed Cargo implementation PR from 2022](https://github.com/rust-lang/cargo/pull/10630)
- [Closed Cargo implementation PR from 2025](https://github.com/rust-lang/cargo/pull/16260)




--------- zulip thread backup -------



matthague Nov 22, 2025

Hey cargo team, I’ve been thinking about https://github.com/rust-lang/cargo/issues/10641 for a while and started a draft RFC to formalize this proposal, get consensus on the design, and keep the feature moving forward https://github.com/matthague/rfcs/blob/master/text/0000-mtls-registry-authentication.

In the proposed solution, we could add on some additional http options that allow us to forward client certificates. In the case that a users client certificates are passphrase protected, we can securely prompt for the password, and pass it on to the handle builder when the curl handle is created.

I think this approach is reasonable since these options really are related to the http configuration, and client certificate passphrases shouldn’t be stored on disk.

I’ve been wondering if there’s a way to do this better. Could/should this somehow be integrated into the credential provider system instead? I would really like if I could write a credential provider plugin that allowed me to manage all of this stuff outside of cargo directly, but that’s not possible currently. If anyone has time I’d love to hear your ideas.

November 24

Jacob Finkelman (Eh2406): The interactions with credential providers and the security implications of having two related but different systems is exactly why I thought this needed in RFC. I also vaguely remember talking to @Josh Triplett about MTLS during early discussions of the credential provider system and asymmetric tokens, But don't remember the details of those discussions. Perhaps he does. That is to say I don't know what the correct answers are, But someone needs to document and think about them carefully.

Josh Triplett: I don't remember mTLS coming up either.Josh Triplett: I think we talked about the approach of the client having a key and using that to do challenge-response to avoid transmitting the token. It's possible mTLS came up then as another alternative.

matthague: As I’ve been learning more about how credential providers work, it might make sense to add optional ssl_cert_blob and ssl_key_blob fields to the CredentialResponse message (maybe these could be b64 encoded). That would take care of things like different credentials for different registries, and credential caching through the current mechanisms. And curl::easy has support for setting client certs and keys from in-memory binary blobs. 
The more I research this topic, the less I want to assume about exactly how these client certificates will be provided (files on disk, hardware/software crypto engines, smart cards, whether the keys are passphrase protected, etc). 
Allowing users to provide a custom plugin that loads thier data into json blobs would be a fairly general approach that ties somewhat nicely into the current credential provider scheme.

bjorn3: ssl_key_blob won't work when the key is stored in a HSM (TPM, securitykey, ...) Instead cargo have to ask the credential provider for the client certificate (or raw public key) and then will have to tell the credential provider a message that needs to be signed and fetch the signature. https://docs.rs/rustls/latest/rustls/sign/struct.CertifiedKey.html

matthague: For HSMs I think we might be able to use curl’s ssl_engine option to configure the engine, and in that case the ssl_key value specifies the ID/label for the engine to know which key to use. Then we wouldn’t have to handle the signing requests in cargo, that could be done on the side by curl and the engine.
This might need some more research to be certain about this approach though.

Jacob Finkelman (Eh2406): Does that lock us into using curl as our back end?

matthague: It looks like reqwest and hyper can also handle certs in blob formats, or from files, but don’t handle engines. 
I’m not sure if this would cause lock in (depends on exactly what features need to be supported), but it would make switching more difficult.

bjorn3: Curl's ssl_engine option seems to just be a string that is passed straight to openssl. Presumably it uses a builtin engine/provider or loads one from a dylib. In any case it would definitively be OpenSSL specific. Rustls would instead require you to pass an implementation of a trait that does the signing. Having a protocol where cargo sends a message to the credential provider and gets back a signature is the only way I can think of that doesn't lock you into OpenSSL or some other TLS library.

matthague: I think if there’s desire to switch to rustls (or some alternative) as the backend in the future, having a protocol for message signing would be a more maintainable approach for HSMs and other engine support.