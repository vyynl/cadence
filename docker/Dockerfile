# syntax=docker/dockerfile:1
# check=skip=SecretsUsedInArgOrEnv

# The CAD_DEMO_AUTH build arg is a boolean compile-time gate, not a secret; the
# lint heuristic flags the name. It is intentionally checked and rejected below.

# Production server image (spec §12.3, §12.8).
#
# The dev demo stack lives in docker/Dockerfile.demo and is a different image
# on purpose: it compiles with MIX_ENV=dev and bakes in the demo password
# strategy. This file never does either.

ARG ELIXIR_VERSION=1.20
ARG OTP_VERSION=29
# Must match the Debian release of the `elixir` build image: the release ships
# the ERTS binary built against that glibc. `elixir:1.20-otp-29` is trixie
# (glibc 2.41); a bookworm runtime fails with `GLIBC_2.38 not found`.
ARG DEBIAN_VERSION=trixie

# -- Build stage -------------------------------------------------------------

FROM elixir:${ELIXIR_VERSION}-otp-${OTP_VERSION} AS build

# The demo password strategy is a compile-time gate (§7.4). Refuse a production
# build that carries it, before any source is copied.
ARG CAD_DEMO_AUTH=
RUN if [ -n "${CAD_DEMO_AUTH}" ]; then \
      echo "CAD_DEMO_AUTH must not be set for a production build (spec §7.4/§12.8)" >&2; \
      exit 1; \
    fi

ENV MIX_ENV=prod \
    LANG=C.UTF-8

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

# Only the umbrella project files first, so `mix deps.get` is cached across
# source-only changes. The umbrella root requires every child's mix.exs to
# exist; their source is copied after the dependency layer.
COPY mix.exs mix.lock ./
COPY apps/cadence_shared/mix.exs apps/cadence_shared/mix.exs
COPY apps/cadence_daemon/mix.exs apps/cadence_daemon/mix.exs
COPY apps/cadence_server/mix.exs apps/cadence_server/mix.exs
COPY config ./config

RUN mix deps.get --only prod

COPY apps ./apps

RUN mix compile --warnings-as-errors
RUN mix release cadence

# -- Runtime stage -----------------------------------------------------------

FROM debian:${DEBIAN_VERSION}-slim AS app

# The release carries ERTS, so the runtime needs glibc, the OpenSSL and
# libstdc++ shared libraries used by the NIFs (bcrypt, axiom_ai, mdex_native),
# ncurses for `erl`, libsctp for the ERTS SCTP probe (no distribution is used),
# and curl for the healthcheck. Alpine is not an option without rebuilding the
# native dependencies against musl.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       ca-certificates \
       curl \
       libncurses6 \
       libsctp1 \
       libstdc++6 \
       openssl \
  && rm -rf /var/lib/apt/lists/* \
  && groupadd --system cadence \
  && useradd --system --gid cadence --home-dir /app --shell /usr/sbin/nologin cadence

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    HOME=/app \
    MIX_ENV=prod \
    RELEASE_DISTRIBUTION=none

WORKDIR /app

COPY --from=build /app/_build/prod/rel/cadence ./

# Persistent state (spec §12.3). `/data/actions` is the mount point for the
# named volume the host Docker daemon mounts into action containers (§8.3);
# `/data/git` and `/data/artifacts` hold the object stores.
RUN mkdir -p /app/tmp /data/git /data/artifacts /data/actions \
  && chown -R cadence:cadence /app /data

USER cadence

EXPOSE 4000

# The app listens on 4000 inside the container by default; set CAD_HTTP_PORT to
# move it (compose uses it as the host publish port and leaves the container on
# 4000). Shell form so the runtime env is expanded.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${CAD_HTTP_PORT:-4000}/health" || exit 1

CMD ["/app/bin/cadence", "start"]
