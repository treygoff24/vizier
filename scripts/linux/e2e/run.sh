#!/bin/bash
# Adapter end-to-end harness for the Linux paste path.
#
# WHAT THIS PROVES
#   The real adapters (ProcessRunner, X11ClipboardWriter + XdotoolKeySender, WlCopyClipboardWriter
#   + WtypeKeySender, the X11/sway focus readers, LinuxPaster) against real desktops in a
#   Debian 13 container:
#     x11  - Xvfb with a Tk text box: LinuxPaster publishes with xclip, presses Ctrl+V with
#            xdotool, and the exact text (unicode included) arrives in the box; a second paste
#            replaces the clipboard.
#     sway - headless sway with foot running `cat > file` in raw mode: focus is read from
#            `swaymsg -t get_tree`, foot is recognised as a terminal, LinuxPaster publishes with
#            wl-copy and wtype sends Ctrl+Shift+V, and the text arrives; a bare Ctrl+V chord
#            arrives as the 0x16 byte (so the chord choice is observable).
#   The tests skip unless VIZIER_E2E_DESKTOP is set (this script sets it, to x11 or sway).
#
# WHAT IT DOES NOT PROVE
#   - GNOME and KDE (portal RemoteDesktop/Clipboard, GlobalShortcuts): a different lane, not covered.
#   - Hyprland, COSMIC, niri; ydotool (needs /dev/uinput and ydotoold); xsel as the X11 fallback.
#   - Real-app quirks (Electron, browsers), focus changes under a real window manager, and a
#     second display server on the same session (XWayland).
#   - macOS. It runs on Linux only.
#
# HOW
#   Builds the test binaries on the host (Swift 6.4 from swiftly), builds the image, then runs one
#   container per desktop with the repo and the Swift toolchain mounted at their host paths
#   (host and image are both Debian 13, so the libraries match) and the test runner binary directly.
#   Usage: scripts/linux/e2e/run.sh [x11|sway ...]   (default: both)
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
# shellcheck disable=SC1091
. "$HOME/.local/share/swiftly/env.sh"
toolchain="${SWIFT_TOOLCHAIN:-$(ls -d "$HOME"/.local/share/swiftly/toolchains/*/ | sort | tail -1)}"
toolchain="${toolchain%/}"
[ -x "$toolchain/usr/bin/swift" ] || { echo "no Swift toolchain at $toolchain (set SWIFT_TOOLCHAIN)" >&2; exit 1; }

modes=("$@"); [ ${#modes[@]} -gt 0 ] || modes=(x11 sway)

echo "== building the tests on the host"
(cd "$repo" && swift build --build-tests >/dev/null)
echo "== building the image"
docker build -q -t vizier-e2e-desktop "$here" >/dev/null

status=0
for mode in "${modes[@]}"; do
  echo "== $mode"
  docker run --rm \
    -v "$repo:$repo" -v "$toolchain:$toolchain:ro" -v "$here:/opt/e2e:ro" \
    -e SWIFT_TOOLCHAIN="$toolchain" \
    -e LD_LIBRARY_PATH="$toolchain/usr/lib/swift/linux" \
    vizier-e2e-desktop /opt/e2e/in-container.sh "$mode" "$repo" || status=$?
done
exit $status
