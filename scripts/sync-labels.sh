#!/usr/bin/env bash
# Create or update the repository's labels from .github/labels.yml, using `gh label create --force`.
#
# Run it by hand, once at publish time and again whenever labels.yml changes. Nothing calls it
# automatically (no workflow, no hook). It never deletes labels.
#
# Usage:
#   scripts/sync-labels.sh --dry-run              print what it would do, change nothing
#   scripts/sync-labels.sh                        apply to the GitHub repository of this script's checkout
#   scripts/sync-labels.sh -R OWNER/REPO          apply to a named repository
#
# Needs the GitHub CLI (`gh`), signed in with a token that can write labels on the repository.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
file="$root/.github/labels.yml"
dry_run=0
repo_args=()

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run|-n) dry_run=1 ;;
    -R|--repo)
      [ $# -ge 2 ] || { echo "sync-labels: $1 needs OWNER/REPO" >&2; exit 2; }
      repo_args=(-R "$2"); shift ;;
    -h|--help) sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "sync-labels: unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

[ -f "$file" ] || { echo "sync-labels: $file not found" >&2; exit 1; }
if [ "$dry_run" -eq 0 ]; then
  command -v gh >/dev/null 2>&1 || { echo "sync-labels: the GitHub CLI (gh) is not installed" >&2; exit 1; }
fi

# gh picks its repository from the directory it runs in. Run it from this checkout, never the
# caller's directory, so labels.yml from here cannot land on some other checkout's repository.
cd "$root"

# labels.yml has a fixed layout (see its header): "- name:", "  color:" and "  description:" lines,
# each value in double quotes. Turn each block into one tab-separated line: name, color, description.
records="$(awk '
  function value(line) {
    sub(/^[^:]*:[ \t]*"/, "", line); sub(/"[ \t]*$/, "", line); return line
  }
  /^- name:/        { if (name != "") emit(); name = value($0); color = ""; desc = ""; next }
  /^[ \t]+color:/   { color = value($0); next }
  /^[ \t]+description:/ { desc = value($0); next }
  function emit() { printf "%s\t%s\t%s\n", name, color, desc }
  END { if (name != "") emit() }
' "$file")"

[ -n "$records" ] || { echo "sync-labels: no labels found in $file" >&2; exit 1; }

count=0
while IFS=$'\t' read -r name color desc; do
  if ! [[ "$color" =~ ^[0-9a-fA-F]{6}$ ]]; then
    echo "sync-labels: label '$name' has a bad color '$color' (need six hex digits)" >&2; exit 1
  fi
  if [ "${#desc}" -gt 100 ]; then
    echo "sync-labels: label '$name' description is ${#desc} characters; GitHub allows 100" >&2; exit 1
  fi
  if [ "$dry_run" -eq 1 ]; then
    printf 'would run: gh label create %q --color %s --description %q --force %s\n' \
      "$name" "$color" "$desc" "${repo_args[*]:-}"
  else
    gh label create "$name" --color "$color" --description "$desc" --force ${repo_args[@]+"${repo_args[@]}"}
  fi
  count=$((count + 1))
done <<< "$records"

if [ "$dry_run" -eq 1 ]; then
  echo "sync-labels: dry run, $count labels, nothing changed"
else
  echo "sync-labels: applied $count labels"
fi
