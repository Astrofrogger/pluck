# Pluck's own relay for Edit Anywhere: iroh-relay at the SAME iroh version as Helpers/PluckIroh (its Cargo.lock),
# started by pluck-relay with an allowlist-only, TLS-only config. The build context is Helpers/:
#   docker build -f PluckRelay/docker/Dockerfile -t pluck-relay Helpers
# Release: when `cargo update -p iroh` moves PluckIroh, change IROH_RELAY_VERSION here too (the workflow refuses a
# mismatch). shortcut: base images pinned by tag, not digest; pin by digest at release.
FROM rust:1.99.0-bookworm AS build
ARG IROH_RELAY_VERSION=1.4.1
RUN cargo install iroh-relay --version "=${IROH_RELAY_VERSION}" --locked --features server --root /out
WORKDIR /src
COPY PluckRelay/Cargo.toml PluckRelay/Cargo.lock ./
COPY PluckRelay/src ./src
RUN cargo build --locked --release

FROM debian:12.12-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/bin/iroh-relay /usr/local/bin/iroh-relay
COPY --from=build /src/target/release/pluck-relay /usr/local/bin/pluck-relay
# The Let's Encrypt cache (a named volume starts with this folder's owner, so user 568 can write it).
RUN mkdir /certs && chown 568:568 /certs
VOLUME /certs
USER 568:568
ENTRYPOINT ["/usr/local/bin/pluck-relay"]
