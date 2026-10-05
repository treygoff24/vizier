# Image for the take end-to-end test (scripts/linux/e2e-take/run.sh): a real X server and Tk window,
# the paste helpers, espeak-ng for synthetic speech, and a real whisper.cpp server built from a pinned
# tag with the ggml-tiny.en model (pinned SHA256). No Swift here: the host's toolchain and the
# host-built `vizier` binary are mounted in by run.sh (same glibc: Debian 13).
FROM debian:13
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        xvfb xdotool xclip xsel x11-utils python3 python3-tk espeak-ng ffmpeg \
        libwayland-client0 libsqlite3-0 libcurl4t64 libstdc++6 libxml2 libncurses6 libedit2 zlib1g libgcc-s1 \
        fonts-dejavu-core procps ca-certificates curl git cmake build-essential \
    && rm -rf /var/lib/apt/lists/*
ARG WHISPER_TAG=v1.9.4
ARG MODEL_SHA256=921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f
RUN git clone --depth 1 --branch "$WHISPER_TAG" https://github.com/ggml-org/whisper.cpp /opt/whisper.cpp \
    && cmake -S /opt/whisper.cpp -B /opt/whisper.cpp/build -DCMAKE_BUILD_TYPE=Release \
         -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON -DGGML_NATIVE=OFF -DBUILD_SHARED_LIBS=OFF \
    && cmake --build /opt/whisper.cpp/build -j"$(nproc)" --target whisper-server \
    && install -m755 /opt/whisper.cpp/build/bin/whisper-server /usr/local/bin/whisper-server \
    && rm -rf /opt/whisper.cpp
RUN curl -fL -o /opt/ggml-tiny.en.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin \
    && echo "$MODEL_SHA256  /opt/ggml-tiny.en.bin" | sha256sum -c -
