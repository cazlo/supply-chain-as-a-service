# Cargo mTLS: Concrete Interface Proposal

This document turns the design questions in
[Cargo mTLS Upstream Research](cargo-mtls-upstream-research.md) into a concrete
protocol and implementation interface, grounded in Cargo's actual source. It is
input for feedback on [rust-lang/rfcs#3907](https://github.com/rust-lang/rfcs/pull/3907),
not a competing proposal.

Code references are to a local clone of `rust-lang/cargo` at commit
`0a28f7930c7b559c37fc221347114f9c6434f2ae` (master, 2026-07-10), checked out at
`~/src/cazlo-ak-forks/cargo`.

Where this document cites the Go work, that work is a **proof of concept**: an
implementation POC attached to the open Go proposal
[golang/go#30119](https://github.com/golang/go/issues/30119), submitted as
[golang/go#80371](https://github.com/golang/go/pull/80371)
([CL 799701](https://go-review.googlesource.com/c/go/+/799701)) toward a future
Go release. It is not merged and the proposal is not accepted; it is cited here
as a worked example of the design decisions, not as shipped precedent.

## What the Cargo source actually shows

These facts change or sharpen several assumptions in the earlier research doc
and in RFC 3907's framing.

### 1. Every request already gets a fresh easy handle

The async client creates a new `Easy2` per request in
[`request_helper`](https://github.com/rust-lang/cargo/blob/0a28f7930c7b559c37fc221347114f9c6434f2ae/src/cargo/util/network/http_async.rs#L121-L169)
(`src/cargo/util/network/http_async.rs:129`). Easy handles are not pooled or
reused. This means the widely feared "leftover identity on a shared handle"
problem **does not exist at the easy-handle level**: applying
`ssl_cert_blob`/`ssl_key_blob` per request is structurally natural.

The real isolation boundary is the `Multi` connection cache
(`http_async.rs:230`), which is shared by the single worker thread and reuses
TCP/TLS connections across requests. Whether libcurl's connection-reuse check
compares client-certificate *blobs* correctly is version-dependent (libcurl has
had too-eager TLS connection reuse bugs, e.g. CVE-2022-27782 fixed in 7.83.1),
and Cargo frequently links a system libcurl. This is the piece that needs
either a per-identity client or a verified minimum libcurl version, not the
easy handle.

### 2. All three registry surfaces share one global client

`GlobalContext::http_async()`
([`context/mod.rs:1936`](https://github.com/rust-lang/cargo/blob/0a28f7930c7b559c37fc221347114f9c6434f2ae/src/cargo/util/context/mod.rs#L1936-L1941))
lazily creates **one** `http_async::Client` (one worker thread, one `Multi`)
used by:

- sparse index fetches — `sources/registry/http_remote.rs:538`;
- crate downloads — `core/package.rs:476`;
- registry API operations including publish — `ops/registry/mod.rs:370`
  (`request_blocking`); and
- pseudo-Git smart-HTTP probing — `sources/git/utils.rs:1599`.

Requests arrive at the transport as plain `http::Request` values. **No registry
identity (`SourceId`) survives to the transport layer.** Any per-registry TLS
identity therefore has to be threaded through the request itself; the natural
mechanism is `http::Extensions` (Cargo already uses response extensions for
`effective_url` in `http_async.rs:272-276`).

### 3. libcurl follows redirects with the handle's certificate

`request_helper` sets `follow_location(true)` (`http_async.rs:133`). libcurl
follows cross-origin redirects inside one transfer, and a client certificate
configured on the handle is presented to every hop. libcurl has no
"same-origin redirects only" option, and its documented protections for
`Authorization` headers on cross-host redirects say nothing about TLS
identities. So origin-scoped identity **requires** Cargo-managed redirects for
identity-carrying requests. Cargo already records `effective_url`, which shows
redirects are currently invisible to callers.

Precedent worth noting: for bearer tokens Cargo already sends the registry
token to whatever origin `config.json`'s `dl` template points at
([`download.rs:67-77`](https://github.com/rust-lang/cargo/blob/0a28f7930c7b559c37fc221347114f9c6434f2ae/src/cargo/sources/registry/download.rs#L67-L77)),
i.e. the "one logical registry, several origins" question is live in Cargo
today. The identity design should be stricter than the token design, not copy
it.

### 4. The protocol crate already has the missing primitives

RFC 3907 leaves rotation, secrecy, and absence semantics open. All three have
existing, shipped answers in `credential/cargo-credential/src/lib.rs`:

- **Version negotiation**: `CredentialHello { v: Vec<u32> }` (`lib.rs:60-63`)
  already carries a *list* of supported versions, and
  `PROTOCOL_VERSION_1` docs (`lib.rs:214-221`) explicitly anticipate a
  `PROTOCOL_VERSION_2`. Cargo's process wrapper currently hard-errors unless
  the provider lists v1 (`util/credential/process.rs:44-54`); v2 negotiation
  slots in there.
- **Rotation**: `CacheControl` (`lib.rs:200-212`) already defines
  `never` / `expires {timestamp}` / `session`, and the token path already
  honors it with a one-minute expiry skew
  ([`auth/mod.rs:664-679`](https://github.com/rust-lang/cargo/blob/0a28f7930c7b559c37fc221347114f9c6434f2ae/src/cargo/util/auth/mod.rs#L656-L726)).
  The RFC's rotation gap disappears if the `tls-identity` response reuses
  `CacheControl` verbatim. A Teleport `tbot` provider would return
  `"cache":"expires"` with the certificate's renewal time; a static-file
  provider returns `"cache":"session"`.
- **Secrecy**: `Secret<T>` (`secret.rs`) serializes transparently but redacts
  `Debug`. This is load-bearing, not cosmetic: Cargo logs every provider
  response through `Debug` at debug level
  (`util/credential/process.rs:74`). The RFC's "MUST NOT log" requirement is
  only met if the key field is typed `Secret<String>` in the protocol crate.
- **Absence and fallback**: the provider chain treats
  `Error::UrlNotSupported` and `Error::NotFound` as fall-through
  (`auth/mod.rs:611-624`). The RFC's "may return empty fields" conflicts with
  this established semantics — "no identity" should be `not-found`, exactly
  like tokens, so multi-provider configurations behave consistently.
- **`args`**: the unexplained `args` field in the RFC's request is the existing
  mechanism by which extra strings from the configured provider command line
  (`credential-provider = ["/path/provider", "--flag"]`) reach the provider
  (`auth/mod.rs:574-580`, `CredentialRequest.args` at `lib.rs:88-90`). The RFC
  just needs to say that.

### 5. One process spawn per request

Cargo spawns the provider, sends one request, and closes stdin
(`util/credential/process.rs:92-115`). A `tls-identity` refresh after expiry is
therefore one extra process execution — cheap for `tbot`-style file readers,
and a reason the `expires` cache mode is workable.

## Proposed protocol v2 (concrete)

### Hello (unchanged shape)

```json
{"v":[1,2]}
```

Cargo selects the highest common version. v1-only providers are never sent
`tls-identity` requests; a registry configured with only v1 providers behaves
exactly as today.

### `tls-identity` request

```json
{
    "v": 2,
    "kind": "tls-identity",
    "registry": {"index-url": "sparse+https://packages.example.internal/index/", "name": "internal"},
    "origin": "https://packages.example.internal:443",
    "args": []
}
```

The addition over RFC 3907 is the explicit **`origin`** field: the canonical
HTTPS origin (lowercased host, explicit port, no path/query/userinfo) that the
identity will be presented to. Because one registry spans several origins
(index, `dl`, `api` — see `RegistryConfig` in
[`cargo-util-schemas/src/index.rs:263-295`](https://github.com/rust-lang/cargo/blob/0a28f7930c7b559c37fc221347114f9c6434f2ae/crates/cargo-util-schemas/src/index.rs#L263-L295)),
Cargo asks **once per (registry, origin) pair** and the provider is the
authorization point: it can return an identity for the registry's front door
and `not-found` for a public CDN origin. Cargo never silently reuses an
identity across origins.

This mirrors the Go POC, which resolves an identity strictly by canonical
HTTPS origin (scheme https, lowercased ASCII/punycode host, default port
normalized to `:443`, no userinfo/path/query/fragment) and never lets a `Host`
header that differs from the connection host influence selection.

### `tls-identity` response

```json
{"Ok":{
    "kind": "tls-identity",
    "certificate": "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----",
    "key": "-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----",
    "cache": "expires",
    "expiration": 1783468800
}}
```

- `certificate`: PEM chain, leaf first (unchanged from RFC 3907).
- `key`: PEM PKCS#8, unencrypted (unchanged; providers decrypt).
- `cache`/`expiration`: the existing `CacheControl` flattening, identical to
  the token response (`lib.rs:184-212`).
- "No identity for this origin": `{"Err":{"kind":"not-found"}}`, enabling
  provider-chain fall-through. Empty-string fields are a protocol error.

### Protocol-crate types

```rust
pub const PROTOCOL_VERSION_2: u32 = 2;

// In Action<'a> (already #[non_exhaustive], tag = "kind"):
#[serde(rename = "tls-identity")]
TlsIdentity {
    /// Canonical HTTPS origin the identity will be presented to.
    origin: &'a str,
},

// In CredentialResponse (already #[non_exhaustive], tag = "kind"):
TlsIdentity {
    /// PEM certificate chain, leaf first.
    certificate: String,
    /// PEM PKCS#8 private key. `Secret` redacts the Debug output that
    /// util/credential/process.rs logs at debug level.
    key: Secret<String>,
    #[serde(flatten)]
    cache: CacheControl,
},
```

Because `Action` and `CredentialResponse` already carry
`#[serde(other)] Unknown` variants, old copies of the `cargo-credential`
library tolerate unknown kinds gracefully; the version negotiation prevents
them from ever being asked.

## Proposed Cargo-side interface

### Auth layer (`src/cargo/util/auth`)

```rust
/// An in-memory TLS client identity for one (registry, origin) pair.
pub struct RegistryTlsIdentity {
    pub certificate: String,     // PEM chain
    pub key: Secret<String>,     // PEM key
}

/// Returns the identity to present to `origin` on behalf of `sid`,
/// or None if no configured provider has one (not-found fall-through).
pub fn tls_identity(
    gctx: &GlobalContext,
    sid: &SourceId,
    origin: &HttpsOrigin,
) -> CargoResult<Option<Arc<RegistryTlsIdentity>>>
```

Implementation is a sibling of `auth_token_optional`
(`auth/mod.rs:656-726`): a `(canonical index url, origin)`-keyed in-memory
cache on `GlobalContext`, the same one-minute expiry skew, the same
`NotFound → Ok(None)` conversion, and the same provider chain via
`credential_action` with `Action::TlsIdentity { origin }`.

`HttpsOrigin` is a newtype constructed only by a canonicalizer with the rules
above (reject non-HTTPS, userinfo, path, query, fragment; lowercase;
normalize port). Requests for non-HTTPS URLs never consult the identity cache
at all — fail-closed by construction rather than by check.

### Transport layer (`src/cargo/util/network`)

**Attaching the identity.** Call sites that know the registry
(`http_remote.rs:538` for the index, `download.rs`/`package.rs:476` for crate
tarballs, `ops/registry/mod.rs:370` for the API) resolve
`tls_identity(gctx, sid, origin_of(url))` and attach it to the request:

```rust
request.extensions_mut().insert(TlsIdentityExt(identity)); // Arc<RegistryTlsIdentity>
```

`request_helper` (`http_async.rs:121`) reads the extension and configures the
fresh per-request handle:

```rust
if let Some(TlsIdentityExt(id)) = parts.extensions.get::<TlsIdentityExt>() {
    handle.ssl_cert_blob(id.certificate.as_bytes())?;
    handle.ssl_cert_type("PEM")?;
    handle.ssl_key_blob(id.key.as_ref().expose().as_bytes())?;
    handle.ssl_key_type("PEM")?;
}
```

All four setters exist on `Easy2` in curl-rust 0.4.49, the version Cargo pins
(`Cargo.toml:48`). Blobs are copied by libcurl (`CURLOPT_SSLKEY_BLOB` copies by
default), so the `Arc` need not outlive the call.

**Redirects.** For identity-carrying requests, set `follow_location(false)`
and handle 3xx in a small Cargo-level loop: re-canonicalize the target origin,
re-run identity selection for the new origin (which usually yields `None` and a
bare request), and cap hops. Non-identity requests keep libcurl redirects
exactly as today, so the change is invisible outside mTLS registries. This is
the same decision as the Go POC, which gives each certificate configuration
its own cloned transport precisely so that every hop re-evaluates certificate
selection.

**Connection cache.** Two acceptable designs, in order of preference:

1. **Per-identity client**: key additional `http_async::Client` instances by
   identity (the global one stays identity-free). Structurally identical to
   the Go POC's map of certificate-config → dedicated transport. Cost: one
   extra worker thread and connection pool per mTLS registry — in practice one
   or two per invocation.
2. **Shared `Multi` + verified reuse**: rely on libcurl comparing client-cert
   blobs on connection reuse, gated on a minimum libcurl version and covered
   by an end-to-end test that interleaves identity and non-identity requests
   to the same host and asserts no connection sharing. Riskier with system
   libcurl.

**The blocking global handle.** `GlobalContext::http()`
(`context/mod.rs:1923-1934`) calls `Easy::reset()` on every borrow, so global
handle state cannot accidentally retain an identity — provided identity
configuration happens strictly *after* the borrow at the call site and never
inside `configure_http_handle` (`network/http.rs`). The identity must not be
added to `CargoHttpConfig` (`util/context/schema.rs`) precisely because
everything there is global-handle configuration.

**Proxy.** When a proxy is configured for the target
(`network/proxy.rs` decides this today), refuse to present an origin identity
in v1 of the feature with a clear error, matching the Go POC (which rejects
HTTPS proxies for mTLS requests outright). libcurl's
`CURLOPT_PROXY_SSLCERT_BLOB` exists for *proxy* client certificates and must
never be conflated with the origin identity.

**TLS backend.** At startup of an identity-carrying request, check
`curl::Version::get().ssl_version()`; on Schannel (Cargo's usual Windows
build, noted in `network/http.rs:148`) fail with an explicit "client
certificates are not supported with this libcurl TLS backend" error rather
than silently continuing unauthenticated. This makes the RFC's platform story
an intentional, testable limitation instead of an accident.

## How this maps onto the Go POC, honestly

The Go work is a POC on an unaccepted proposal (golang/go#30119, PR #80371 /
CL 799701, targeting a future Go release; Go was in code freeze when it was
submitted). Its value here is that it already made — and tested — the same
five decisions this interface proposes for Cargo:

| Decision | Go POC | Proposed for Cargo |
| --- | --- | --- |
| Identity scope | canonical HTTPS origin, strict normalizer | `HttpsOrigin` newtype + per-(registry, origin) provider query |
| Redirects | per-config cloned transport; selection re-evaluated per request | `follow_location(false)` + Cargo-level redirect loop re-selecting per origin |
| Connection isolation | dedicated `http.Transport` per certificate config | dedicated `http_async::Client` per identity |
| Fail-closed composition | rejects GOINSECURE and HTTPS proxies with mTLS | HTTPS-only by construction; refuse proxied identity requests; hard error on Schannel |
| Test surface | client-cert-verifying test server; script tests for origin matching, redirects, lazy load, combined/separate PEM, proxy | same matrix against Cargo's `credential_process.rs` / `registry_auth.rs` / `https.rs` suites, plus a client-cert-verifying fixture |

The one place Cargo's design is *stronger* than the Go POC: the credential
provider indirection means key material arrives in memory over stdio rather
than as file paths in an environment variable, and rotation gets first-class
`expires` semantics instead of relying on process lifetime.

## Answers this gives to the open RFC review questions

Eh2406's four unanswered questions on RFC 3907 (2026-01-19), answered from the
code above:

1. **"What do these `args` represent?"** — the provider-command arguments from
   the registry's `credential-provider` configuration, passed through
   `credential_action` exactly as for token requests (`auth/mod.rs:574-580`).
2. **"Empty fields vs `not-found`?"** — `not-found`, to preserve
   provider-chain fall-through semantics (`auth/mod.rs:611-624`); empty fields
   should be a protocol error.
3. **"PEM opinions?"** — PEM cert-chain + PKCS#8 key is what the surveyed
   ecosystem already exchanges (pip, uv, Bundler, Conan combined or separate
   PEM; the Go POC consumes the same pair via `tls.LoadX509KeyPair`), and it
   is what Teleport `tbot` writes to disk. The genuine constraint is not
   aesthetic: libcurl's Schannel backend cannot take a separate PEM key blob
   at all, so the format decision must come with an explicit
   backend-compatibility statement either way. RustCrypto input is still worth
   having, but interchange-format network effects favor PEM.
4. **"Should registries use mTLS, tokens, or both?"** — both, with different
   jobs. In the zero-trust deployment pattern (Teleport Application Access in
   front of Artifact Keeper; the same shape as Artifactory/Nexus behind an
   mTLS-terminating access proxy), mTLS is the *outer* workload/user identity
   that gates reachability, and the registry token remains the *inner*
   application authorization for publish/yank/owner. The RFC author's own
   nginx+SSO reverse-proxy use case is the same shape. Guidance: mTLS
   authenticates the connection; `auth-required` tokens keep authorizing
   operations; neither replaces the other.

## Suggested next step

Fold the `origin` request field, `CacheControl` reuse, `Secret<String>` key
typing, and `not-found` semantics into feedback on RFC 3907 (Zulip first, per
the sequencing in the upstream research doc). Each is a small, code-grounded
delta to the existing draft rather than a redesign, and together they close
every unresolved item except CSR/HSM flows, which the RFC already defers.
