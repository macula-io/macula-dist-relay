# macula-dist-relay — Dedicated QUIC relay for Erlang distribution over the Macula mesh.
# Multi-stage build: builder (Erlang + Rust for macula NIFs) → runtime (Alpine + Erlang runtime libs).

FROM erlang:27-alpine AS builder

WORKDIR /build

# Build deps: perl/openssl-dev for QUIC, cmake/build-base for native libs.
# Rust intentionally NOT pulled from apk: Alpine 3.22 ships rustc 1.87,
# but macula 3.15.x's Rust NIF deps (time@0.3.47, time-core@0.1.8,
# time-macros@0.2.27) require rustc 1.88+. Use rustup for current stable.
RUN apk add --no-cache \
    git curl bash \
    build-base cmake \
    perl linux-headers openssl-dev

# Install Rust via rustup (always current stable)
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain stable --profile minimal
ENV PATH="/root/.cargo/bin:${PATH}"
# musl-targeted rustup defaults to crt-static, which can't produce
# cdylibs (the macula_quic NIF needs one). Disable it.
ENV RUSTFLAGS="-C target-feature=-crt-static"

# rebar3
RUN curl -fsSL https://s3.amazonaws.com/rebar3/rebar3 -o /usr/local/bin/rebar3 && \
    chmod +x /usr/local/bin/rebar3

# Cache deps layer
COPY rebar.config rebar.lock* ./
RUN rebar3 get-deps

# Source
COPY config/ config/
COPY src/ src/

# Compile + release
RUN rebar3 as prod compile && rebar3 as prod release

# ---- Runtime image ----
FROM alpine:3.22

RUN apk add --no-cache \
    ncurses-libs \
    libstdc++ \
    libgcc \
    openssl \
    ca-certificates

WORKDIR /app

COPY --from=builder /build/_build/prod/rel/macula_dist_relay ./

# The dist relay listens on UDP — the default is 4434 (distinct from the station's 4433).
# Override via MACULA_DIST_PORT env var.
ENV MACULA_DIST_PORT=4434

EXPOSE 4434/udp

# Foreground mode so Docker can manage the lifecycle + observe logs.
ENTRYPOINT ["/app/bin/macula_dist_relay"]
CMD ["foreground"]
