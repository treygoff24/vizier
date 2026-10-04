FROM debian:13

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends libwayland-dev \
        binutils git gnupg2 libc6-dev libcurl4-openssl-dev libedit2 \
        libgcc-14-dev libpython3-dev libsqlite3-dev libstdc++-14-dev \
        libxml2-dev libncurses-dev libz3-dev pkg-config tzdata zlib1g-dev unzip \
        binutils-gold libicu-dev libedit-dev uuid-dev gcc zip \
        ffmpeg dbus python3-venv libsystemd0 ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 1000 --shell /bin/bash vizier \
    && install -d -o vizier -g vizier -m 0700 /home/vizier/runtime \
    && install -d -o vizier -g vizier /home/vizier/work

USER vizier
ENV HOME=/home/vizier
WORKDIR /home/vizier
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# Verify the swiftly bootstrap as documented at swift.org/install/linux/swiftly/.
# Pin swiftly as well as Swift; Debian 13 support is present in swiftly 1.2.0.
# The keys are swift.org/keys/all-keys.asc, committed here: GitHub's runners are served
# something else at that URL, which gpg cannot import.
COPY --chown=vizier:vizier swift-keys.asc /home/vizier/swift-keys.asc
RUN archive="swiftly-1.2.0-$(uname -m).tar.gz"; \
    curl --fail --location --retry 3 -o "$archive" "https://download.swift.org/swiftly/linux/$archive"; \
    curl --fail --location --retry 3 -o "$archive.sig" "https://download.swift.org/swiftly/linux/$archive.sig"; \
    gpg --batch --import swift-keys.asc; \
    gpg --batch --verify "$archive.sig" "$archive"; \
    tar -xzf "$archive"; \
    ./swiftly init --assume-yes --no-modify-profile --skip-install --platform debian13; \
    . /home/vizier/.local/share/swiftly/env.sh; \
    swiftly install 6.4.0 --assume-yes --verify --use; \
    hash -r; \
    swift --version; \
    rm -f "$archive" "$archive.sig" swift-keys.asc

ENV XDG_RUNTIME_DIR=/home/vizier/runtime
ENV VIZIER_REQUIRE_FFMPEG=1
COPY in-container.sh /opt/ci/in-container.sh
WORKDIR /home/vizier/work
ENTRYPOINT ["/bin/bash", "/opt/ci/in-container.sh"]
