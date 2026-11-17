# Pluck Review host image: pluck-review (+ pluck-iroh for remote access) for the target arch, with
# ffmpeg for review copies. The build context is Helpers/:
#   docker build -f PluckReview/docker/Dockerfile -t pluck-review-host Helpers
# The builder and the runtime are both Debian bookworm, so the glibc matches.
# Exact versions, so a rebuild gets the same toolchain and base (the CI's RUST_TOOLCHAIN matches).
# shortcut: pinned by tag, not digest; pin by digest at release (docker buildx imagetools inspect <tag>).
FROM rust:1.99.0-bookworm AS build-review
WORKDIR /src
COPY PluckReview/Cargo.toml PluckReview/Cargo.lock ./
COPY PluckReview/src ./src
COPY PluckReview/vendor ./vendor
# The release tag becomes the reported version (empty: Cargo.toml's).
ARG PLUCK_REVIEW_VERSION=
ENV PLUCK_REVIEW_VERSION=${PLUCK_REVIEW_VERSION}
# Pure-Rust DTLS crypto on Linux (the Mac build uses Apple's).
RUN cargo build --locked --profile dist --no-default-features --features portable

FROM rust:1.99.0-bookworm AS build-iroh
WORKDIR /src
COPY PluckIroh/Cargo.toml PluckIroh/Cargo.lock ./
COPY PluckIroh/src ./src
RUN cargo build --locked --profile dist

FROM debian:12.12-slim
# ffmpeg/ffprobe make the review copies (Debian's build: GPL, used as a separate program; it has
# drawtext for burned-in watermarks, with the DejaVu font). poppler-utils' pdftoppm renders PDF pages.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg poppler-utils fonts-dejavu-core ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build-review /src/target/dist/pluck-review /usr/local/bin/pluck-review
COPY --from=build-iroh /src/target/dist/pluck-iroh /usr/local/bin/pluck-iroh
ENV HOME=/data
WORKDIR /data
VOLUME /data
# Runs as whatever user the compose file sets (TrueNAS apps: 568); never as root.
USER 568:568
ENTRYPOINT ["/usr/local/bin/pluck-review", "--host", "/data"]
