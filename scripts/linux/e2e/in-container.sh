#!/bin/bash
# Runs inside the container (run.sh starts it): brings up the desktop named by $1 (x11 or sway)
# and runs the adapter e2e tests against it. The repo is mounted at its host path (the test
# bundle is linked to .build's own paths) and the Swift runtime libraries come from the mounted
# toolchain through LD_LIBRARY_PATH; no compiler runs here.
set -euo pipefail
mode="$1"
repo="$2"
export HOME=/tmp/home
mkdir -p "$HOME" /tmp/e2e
export E2E_OUT=/tmp/e2e
export XDG_RUNTIME_DIR=/tmp/xdg
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
cd "$repo"

cleanup() { jobs -p | xargs -r kill 2>/dev/null || true; }
trap cleanup EXIT

wait_for() { # wait_for <seconds> <description> <command...>
  local limit=$1 what=$2; shift 2
  for _ in $(seq 1 $((limit * 10))); do "$@" >/dev/null 2>&1 && return 0; sleep 0.1; done
  echo "e2e: timed out waiting for $what" >&2; return 1
}

has_window() { swaymsg -t get_tree | grep -q "\"pid\": $1,"; }

case "$mode" in
x11)
  export DISPLAY=:99
  Xvfb :99 -screen 0 1280x720x24 >/tmp/xvfb.log 2>&1 &
  wait_for 10 "Xvfb" xdpyinfo
  python3 /opt/e2e/tkwindow.py "$E2E_OUT/x11.out" >/tmp/tk.log 2>&1 &
  wait_for 10 "the Tk window" test -e "$E2E_OUT/x11.out.ready"
  export XDG_SESSION_TYPE=x11 XDG_CURRENT_DESKTOP=XFCE
  filter=AdapterE2EX11
  ;;
sway)
  export WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman
  export XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=sway
  printf 'output * resolution 1280x720\ndefault_border none\n' > /tmp/sway.conf
  sway -c /tmp/sway.conf >/tmp/sway.log 2>&1 &
  wait_for 15 "the sway socket" bash -c 'ls "$XDG_RUNTIME_DIR"/wayland-* "$XDG_RUNTIME_DIR"/sway-ipc.*.sock'
  export WAYLAND_DISPLAY=$(basename "$(ls "$XDG_RUNTIME_DIR"/wayland-* | grep -v lock | head -1)")
  export SWAYSOCK=$(ls "$XDG_RUNTIME_DIR"/sway-ipc.*.sock | head -1)
  wait_for 10 "swaymsg" swaymsg -t get_version
  # Two terminals in raw mode, A and B, each writing every byte it receives to its own file. Their
  # pids (which sway reports as the windows' pids) are recorded so the tests can move real focus.
  foot -e sh -c "stty raw -echo; exec cat > $E2E_OUT/foot.out" >/tmp/foot.log 2>&1 &
  echo $! > "$E2E_OUT/footA.pid"
  wait_for 15 "window A" has_window "$(cat "$E2E_OUT/footA.pid")"
  foot -e sh -c "stty raw -echo; exec cat > $E2E_OUT/foot2.out" >/tmp/foot2.log 2>&1 &
  echo $! > "$E2E_OUT/footB.pid"
  wait_for 15 "window B" has_window "$(cat "$E2E_OUT/footB.pid")"
  sleep 1
  filter=AdapterE2ESway
  ;;
*) echo "unknown mode $mode" >&2; exit 2 ;;
esac

export VIZIER_E2E_DESKTOP="$mode"
.build/debug/VizierCLITests-test-runner --testing-library swift-testing --filter "$filter"
