FROM debian:trixie-slim

ARG TARGETARCH
RUN ARCH="${TARGETARCH:-$(dpkg --print-architecture)}" && \
    apt-get update && apt-get install -y --no-install-recommends \
    wget \
    libguestfs-tools \
    qemu-utils \
    jq \
    ca-certificates \
    procps \
    cron \
    tini \
    "linux-image-$ARCH" \
    tzdata \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN touch /var/log/cron.log

ENV LIBGUESTFS_BACKEND=direct

WORKDIR /app/src

COPY src/ /app/src/
COPY config/ /app/config/

RUN chmod +x builder.sh entrypoint.sh

ENV OUTPUT_DIR=/output

RUN mkdir -p /output

HEALTHCHECK --interval=5m --timeout=10s --start-period=2h --retries=2 \
    CMD test -f /output/images.json && \
        find /output -maxdepth 1 -name '*.qcow2' -mtime -2 | grep -q .

ENTRYPOINT ["/usr/bin/tini", "--", "./entrypoint.sh"]