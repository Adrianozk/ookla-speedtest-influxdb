FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        gosu \
        jq \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 collector

WORKDIR /app

COPY --chown=collector:collector scripts/entrypoint.sh scripts/collector.sh /app/scripts/
RUN chmod 755 /app/scripts/*.sh

ENTRYPOINT ["/app/scripts/entrypoint.sh"]
