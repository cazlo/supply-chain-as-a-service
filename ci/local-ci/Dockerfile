# Local CI image: mirrors the upstream backend `test-backend-unit` + `coverage`
# jobs so backend changes can be iterated on locally with the same gates the
# reviewer runs. Toolchain pinned to the version the production Dockerfile uses
# (artifact-keeper/docker/Dockerfile.backend: rustup --default-toolchain 1.93.0).
FROM rust:1.93-bookworm

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      python3 git postgresql-client ca-certificates unzip \
      pkg-config make perl libssl-dev zlib1g-dev liblzma-dev libbz2-dev \
 && rm -rf /var/lib/apt/lists/*

# protoc: the backend's prost build-script needs it. Pin the same version the
# production Dockerfile downloads (artifact-keeper/docker/Dockerfile.backend) so
# generated protobuf code matches.
RUN ARCH="$(uname -m)" \
 && case "$ARCH" in \
      x86_64)  PA="linux-x86_64" ;; \
      aarch64) PA="linux-aarch_64" ;; \
      *)       echo "unsupported arch: $ARCH" >&2; exit 1 ;; \
    esac \
 && curl --proto '=https' --tlsv1.2 -sSfL \
      "https://github.com/protocolbuffers/protobuf/releases/download/v29.3/protoc-29.3-${PA}.zip" -o /tmp/protoc.zip \
 && unzip -q /tmp/protoc.zip -d /usr/local && rm /tmp/protoc.zip

# llvm-tools-preview provides the coverage instrumentation cargo-llvm-cov needs.
RUN rustup component add llvm-tools-preview

# Prebuilt tool binaries via cargo-binstall (no slow from-source compile). These
# live in the image's CARGO_HOME bin (/usr/local/cargo/bin, on PATH); the
# registry/build caches are redirected to a named volume at run time.
RUN curl -L --proto '=https' --tlsv1.2 -sSf \
      https://raw.githubusercontent.com/cargo-bins/cargo-binstall/main/install-from-binstall-release.sh | bash \
 && cargo binstall -y cargo-nextest cargo-llvm-cov sqlx-cli

# The repo is bind-mounted with host ownership; let git operate on it anyway.
RUN git config --global --add safe.directory '*'

WORKDIR /work
