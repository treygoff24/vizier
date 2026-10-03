FROM debian:trixie
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    dpkg-dev lintian binutils ca-certificates curl imagemagick file ripgrep \
    libcurl4t64 libsqlite3-0 libsystemd0 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /repo
