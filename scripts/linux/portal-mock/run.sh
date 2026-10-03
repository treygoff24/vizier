#!/usr/bin/env bash
set -euo pipefail
# Usage: run.sh swift test --skip-build --parallel --num-workers 8 --filter Portal
# Creates a private session bus. Never connects the mock to the user's desktop bus.
root=$(cd -- "$(dirname -- "$0")/../../.." && pwd)
if [[ "${1:-}" != --inside ]]; then
    command -v dbus-run-session >/dev/null || { echo 'Install dbus-daemon (dbus-run-session)' >&2; exit 1; }
    venv="$root/.build/portal-mock-venv"
    if [[ ! -x "$venv/bin/python" ]]; then
        python3 -m venv "$venv"
    fi
    "$venv/bin/python" -m pip install --quiet 'dbus-next==0.2.3'
    export VIZIER_MOCK_PYTHON="$venv/bin/python"
    exec dbus-run-session -- "$0" --inside "$@"
fi
shift
[[ $# -gt 0 ]] || { echo 'Pass the targeted test command' >&2; exit 1; }
ready=$(mktemp /tmp/vizier-portal-ready.XXXXXX)
# mktemp created an empty file; readiness means a nonempty file, not existence.
"$VIZIER_MOCK_PYTHON" "$root/scripts/linux/portal-mock/mock.py" "$ready" &
mock_pid=$!
cleanup() {
    if kill -0 "$mock_pid" 2>/dev/null; then
        kill "$mock_pid"
    fi
    wait "$mock_pid" 2>/dev/null || true
    # This exact file was created by this script and has no user data.
    if [[ "$ready" == /tmp/vizier-portal-ready.* && -f "$ready" ]]; then
        unlink "$ready"
    fi
}
trap cleanup EXIT
for _ in {1..100}; do
    [[ -s "$ready" ]] && break
    kill -0 "$mock_pid" 2>/dev/null || { echo 'Mock portal exited before ready' >&2; exit 1; }
    sleep 0.05
done
[[ -s "$ready" ]] || { echo 'Mock portal did not become ready' >&2; exit 1; }
export VIZIER_PORTAL_MOCK="$DBUS_SESSION_BUS_ADDRESS"
"$@"
