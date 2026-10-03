#!/usr/bin/env bash
# Usage: build-deb.sh [VERSION]; optional VIZIER_BINARY skips the release build.
set -euo pipefail
# shellcheck source=scripts/linux/package/common.sh
. "$(dirname -- "$0")/common.sh"
docker run --rm --user "$(id -u):$(id -g)" \
    -v "$REPO:/repo:ro" -v "$OUT:/out" \
    vizier-package-tools bash /repo/scripts/linux/package/assemble-deb.sh "$VERSION"
echo "$OUT/vizier_${VERSION}_amd64.deb"
