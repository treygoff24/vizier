# The desktop the adapter e2e tests run in: a real X server and a real (headless) wlroots
# compositor, with the helpers the Linux paste adapters drive. No Swift here: the host's
# toolchain and the host-built test binaries are mounted in by run.sh (same glibc: Debian 13).
FROM debian:13
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        xvfb xdotool xclip xsel x11-utils \
        sway wtype wl-clipboard foot \
        python3 python3-tk espeak-ng \
        libsqlite3-0 libcurl4t64 libstdc++6 libxml2 libncurses6 libedit2 zlib1g libgcc-s1 \
        fonts-dejavu-core procps ca-certificates \
    && rm -rf /var/lib/apt/lists/*
