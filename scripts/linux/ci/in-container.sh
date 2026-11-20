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
# Each test run is bounded. The suites take seconds; a run that stops making progress (a test
# that hangs, or a cooperative thread pool that every test is parked on) fails here with the
# tests that started still on screen, instead of holding the CI job until its own timeout.
limit=${VIZIER_CI_TEST_LIMIT:-600}
bounded() {
    local status=0
    timeout --kill-after=30 "$limit" "$@" || status=$?
    if [[ $status == 124 || $status == 137 ]]; then
        printf '\n%s\n' "Linux CI: the test run passed its ${limit} s limit and was stopped; look for tests that started and never finished" >&2
    fi
    return "$status"
}
args=(swift test --skip-build --parallel --num-workers 8 --xunit-output /home/vizier/tests.xml)
if [[ -n "${VIZIER_CI_FILTER:-}" ]]; then
    args+=(--filter "$VIZIER_CI_FILTER")
fi
bounded "${args[@]}"
scripts/linux/portal-mock/run.sh timeout --kill-after=30 "$limit" swift test --skip-build --parallel --num-workers 8 \
    --filter Portal --xunit-output /home/vizier/portal-tests.xml

# SwiftPM writes a separate xUnit report for Swift Testing. Count its test cases
# rather than parsing parallel console output, which can interleave skip lines.
python3 - <<'PY'
from pathlib import Path
from xml.etree import ElementTree

print("\nLinux CI test counts:")
for label, name in (("Tests", "tests"), ("Portal mock", "portal-tests")):
    report = Path("/home/vizier") / f"{name}-swift-testing.xml"
    cases = ElementTree.parse(report).findall(".//testcase")
    skipped = sum(case.find("skipped") is not None for case in cases)
    passed = len(cases) - skipped
    if not passed:
        raise SystemExit(f"{label}: missing nonzero passing Swift Testing count")
    print(f"{label}: {passed} passed, {skipped} skipped ({len(cases)} reported)")
PY
