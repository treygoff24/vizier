#!/bin/bash
# Take end-to-end harness for the Linux port.
#
# WHAT THIS PROVES
#   A real host-built `vizier daemon`, run as an unprivileged user with the default Linux config
#   (local mode: whisper-server on 127.0.0.1:8738), takes one dictation from start to finish in a
#   Debian 13 container: a recorder command streams espeak-ng speech as 16 kHz s16le (like pw-record
#   would), `vizier toggle` starts and stops the take, a real whisper.cpp server (pinned tag, pinned
#   ggml-tiny.en model SHA256) transcribes the saved FLAC, and the text is pasted with the real
#   xclip + xdotool adapters into a Tk window under Xvfb. It then asserts: at least 6 of the 9
#   spoken words are in the window; `vizier last --json` equals the pasted text; `vizier history
#   --json` shows outcome pasted; the take's FLAC exists under XDG_DATA_HOME/vizier/Takes and ffmpeg
#   decodes it to roughly the streamed duration.
#
# WHAT IT DOES NOT PROVE
#   - A real microphone or PipeWire/PulseAudio (the recorder is a script).
#   - Wayland, GNOME/KDE portals, global shortcuts, notifications, secret service.
#   - Accuracy of the production model (tiny.en here, not large-v3-turbo) or of non-English speech.
#   - Cloud modes or cleanup (the default Linux mode is local with the filler filter, no LLM cleanup).
#   - macOS.
#
# HOW
#   Builds `vizier` on the host, builds the image (whisper.cpp compile and model download are cached
#   in the image layers, so reruns are fast), mounts the repo and the swiftly toolchain read-only,
#   runs as the host uid. VIZIER_E2E_MUTATE=silence makes the recorder stream silence, and nopaste turns xdotool
#   into a no-op; either run must go red. Usage: scripts/linux/e2e-take/run.sh
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
# shellcheck disable=SC1091
. "$HOME/.local/share/swiftly/env.sh"
toolchain="${SWIFT_TOOLCHAIN:-$(ls -d "$HOME"/.local/share/swiftly/toolchains/*/ | sort | tail -1)}"
toolchain="${toolchain%/}"
[ -x "$toolchain/usr/bin/swift" ] || { echo "no Swift toolchain at $toolchain (set SWIFT_TOOLCHAIN)" >&2; exit 1; }

echo "== building vizier on the host"
(cd "$repo" && swift build --product vizier >/dev/null)
echo "== building the image (first run compiles whisper.cpp)"
docker build -q -t vizier-e2e-take "$here" >/dev/null

docker run --rm --user "$(id -u):$(id -g)" \
  -v "$repo:$repo:ro" -v "$toolchain:$toolchain:ro" -v "$here:/opt/e2e:ro" \
  -e LD_LIBRARY_PATH="$toolchain/usr/lib/swift/linux" \
  -e VIZIER_E2E_MUTATE="${VIZIER_E2E_MUTATE:-}" \
  vizier-e2e-take /opt/e2e/in-container.sh "$repo"
