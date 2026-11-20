#!/usr/bin/env bash
# Sourced by install.sh and its check; sourcing this file never stops a process.

# Wait for the installed executables to quit, then stop any that remain. Never match by process
# name: a benchmark running from a copied bundle has the same name and must survive an install.
stop_installed_copies() ( # <installed executable> [legacy installed executable]
  installed_pids() {
    ps -axo pid=,comm= | awk -v a="$1" -v b="${2:-}" \
      '{ pid = $1; sub(/^ *[0-9]+ /, ""); if ($0 == a || $0 == b) print pid }'
  }
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -n "$(installed_pids "$@")" ] || break; sleep 0.3; done
  for pid in $(installed_pids "$@"); do kill "$pid" 2>/dev/null || true; done
)
