#!/usr/bin/env bash
set -euo pipefail
[[ $(id -u) != 0 ]] || { echo 'Linux CI must run as non-root' >&2; exit 1; }
[[ -d "$XDG_RUNTIME_DIR" && $(stat -c '%u:%a' "$XDG_RUNTIME_DIR") == "$(id -u):700" ]] || {
    echo 'XDG_RUNTIME_DIR must be owned by the test user with mode 0700' >&2
    exit 1
}
# shellcheck disable=SC1091
. "$HOME/.local/share/swiftly/env.sh"
swift --version
swiftly --version
ffmpeg -version
export VIZIER_REQUIRE_FFMPEG=1

# /checkout is read-only; all builds, pip installs and test writes use this copy.
# Never import host .build state or worktree Git/Beads pointers into the container.
# Copy what git would: tracked files plus untracked files that are not ignored, so local
# ignored state (agent pointers, lock files, caches) never enters and never blocks the copy.
if git -c safe.directory=/checkout -C /checkout ls-files -z --cached --others --exclude-standard > /tmp/files 2>/dev/null; then
    # The beads ledger is private to the host user and not needed to build or test.
    grep -zv '^\.beads/' /tmp/files > /tmp/files.build || true
    tar -C /checkout --null -T /tmp/files.build -cf - | tar -xf -
else
    # Not a usable git checkout (a linked worktree whose git dir is not mounted): copy all.
    tar -C /checkout --exclude=./.git --exclude=./.beads --exclude=./.build \
        --exclude=./.swiftpm --exclude=./.cache --exclude=./build -cf - . | tar -xf -
fi

swift build --build-tests --jobs 8
args=(swift test --skip-build --parallel --num-workers 8)
if [[ -n "${VIZIER_CI_FILTER:-}" ]]; then
    args+=(--filter "$VIZIER_CI_FILTER")
fi
"${args[@]}" 2>&1 | tee /home/vizier/tests.log
scripts/linux/portal-mock/run.sh swift test --skip-build --parallel --num-workers 8 \
    --filter Portal 2>&1 | tee /home/vizier/portal-tests.log

# Report each Swift Testing count, and reject an accidental empty selection.
python3 - <<'PY'
import pathlib
import re

print("\nLinux CI test counts:")
for label, name in (("Tests", "tests.log"), ("Portal mock", "portal-tests.log")):
    text = (pathlib.Path("/home/vizier") / name).read_text()
    matches = re.findall(r"Test run with (\d+) tests?\b[^\n]* passed[^\n]*", text)
    reported = sum(map(int, matches))
    skipped = len(re.findall(r"^.*\bTest (?!run with )[^\n]* skipped\.", text, re.MULTILINE))
    if reported <= skipped:
        raise SystemExit(f"{label}: missing nonzero passing Swift Testing count")
    print(f"{label}: {reported - skipped} passed, {skipped} skipped ({reported} reported)")
PY
