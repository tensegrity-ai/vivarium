# Build stage
FROM hexpm/elixir:1.19.5-erlang-28.3-debian-bookworm-20260406-slim AS build

RUN apt-get update -y && apt-get install -y build-essential git && \
    apt-get clean && rm -f /var/lib/apt/lists/*_*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

COPY keeper/mix.exs keeper/mix.lock ./
RUN mix deps.get --only prod
RUN mix deps.compile

COPY keeper/config config
COPY keeper/lib lib
# Place at /seed and /bootstrap to match Path.expand("../../../seed", "/app/lib/keeper")
COPY seed /seed
COPY bootstrap /bootstrap

RUN mix compile
RUN mix release

# Runtime stage
FROM debian:bookworm-slim

RUN apt-get update -y && apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates && \
    apt-get clean && rm -f /var/lib/apt/lists/*_*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app

COPY --from=build /app/_build/prod/rel/keeper ./
COPY --from=build /bootstrap/target/x86_64-unknown-linux-musl/release/vivarium-bootstrap /bootstrap/target/x86_64-unknown-linux-musl/release/vivarium-bootstrap

CMD ["/app/bin/keeper", "start"]
