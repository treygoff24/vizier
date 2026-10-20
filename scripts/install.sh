#!/usr/bin/env bash
# Build Vizier.app, install it to ~/Applications, and relaunch it. The path, bundle id, and
# signing identity stay fixed so the Microphone and Accessibility grants carry over.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
dest="$HOME/Applications/Vizier.app"

bash "$repo/scripts/build-app.sh"

# Quitting by bundle id reaches a copy installed under the old name too (Vizier was Dictum until
# 2026-10-03), whose process is named Dictum.
osascript -e 'tell application id "net.praxient.dictum" to quit' >/dev/null 2>&1 || true
# Wait for, and if need be stop, only the processes running the installed copies, matched by executable
# path. Never match by process name: a command-line run of another copy of the binary (a benchmark run
# from a copied bundle, say) is also named Vizier and must survive an install.
installed_pids() {
  ps -axo pid=,comm= | awk -v a="$dest/Contents/MacOS/Vizier" -v b="$HOME/Applications/Dictum.app/Contents/MacOS/Dictum" \
    '{ pid = $1; sub(/^ *[0-9]+ /, ""); if ($0 == a || $0 == b) print pid }'
}
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -n "$(installed_pids)" ] || break; sleep 0.3; done
for pid in $(installed_pids); do kill "$pid" 2>/dev/null || true; done

mkdir -p "$HOME/Applications"
if [ -e "$dest" ]; then rm -rf -- "$dest"; fi
ditto "$repo/build/Vizier.app" "$dest"
codesign --verify --strict "$dest"

# The copy installed before the rename: move it to the Trash (never delete it outright), and only
# when it is this app (its bundle id says so). Its data moves when Vizier first launches.
legacy="$HOME/Applications/Dictum.app"
if [ -d "$legacy" ] && [ "$(plutil -extract CFBundleIdentifier raw -o - "$legacy/Contents/Info.plist" 2>/dev/null)" = "net.praxient.dictum" ]; then
  if osascript -e 'on run argv' -e 'set target to POSIX file (item 1 of argv) as alias' \
      -e 'tell application "Finder" to delete target' -e 'end run' "$legacy" >/dev/null; then
    echo "moved $legacy to the Trash"
  else
    echo "could not move $legacy to the Trash; it is no longer needed, so remove it yourself" >&2
  fi
fi

# Seed API keys into the keychain through the installed binary, so each item's access list names
# Vizier. Only keys set in the environment are seeded: ELEVENLABS_API_KEY and GEMINI_API_KEY. A key
# travels on a pipe: never on a command line, never printed. Without keys, Apple mode still works.
seed() { # seed <keychain account> <environment variable name>
  local value=${!2:-}
  [ -n "$value" ] || return 0
  if ! printf %s "$value" | "$dest/Contents/MacOS/Vizier" --store-key "$1"; then
    echo "the $1 key was not seeded; modes that use it will record but not transcribe" >&2
  fi
}
seed elevenlabs ELEVENLABS_API_KEY
seed gemini GEMINI_API_KEY

open "$dest"
echo "installed $dest"
