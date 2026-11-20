#!/usr/bin/env bash
# Exercises the macOS process matcher with two disposable, same-named binaries. Never installs or
# runs Vizier.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=stop-installed-copies.sh
source "$repo/scripts/stop-installed-copies.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/vizier-install-stop.XXXXXX")
installed_pid='' other_pid=''
cleanup() {
  for pid in "$installed_pid" "$other_pid"; do
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  rm -rf -- "$work"
}
trap cleanup EXIT
fail() { echo "FAIL $1" >&2; exit 1; }
started() {
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ "$(ps -ww -p "$1" -o comm=)" = "$2" ] && return 0
    kill -0 "$1" 2>/dev/null || return 1
    sleep 0.05
  done
  return 1
}

# Use a unique name, including when checking a regression that matches only by process name.
work=$(cd "$work" && pwd -P)
name="vzstop-$$"
installed="$work/installed copy/$name"
other="$work/other copy/$name"
mkdir "${installed%/*}" "${other%/*}"
cp /bin/sleep "$installed"
# macOS can reject the system binary's original signature when it is copied out of /bin.
codesign --force --sign - "$installed"
cp "$installed" "$other"
"$installed" 15 & installed_pid=$!
"$other" 15 & other_pid=$!
started "$installed_pid" "$installed" || fail "installed fixture did not start"
started "$other_pid" "$other" || fail "other fixture did not start"

stop_installed_copies "$installed"
status=0
wait "$installed_pid" 2>/dev/null || status=$?
installed_pid=
[ "$status" = 143 ] || fail "the process at the installed path did not receive SIGTERM"
kill -0 "$other_pid" 2>/dev/null || fail "the same-named process at the other path was stopped"
echo "ok   stopped only the process at the installed path"
