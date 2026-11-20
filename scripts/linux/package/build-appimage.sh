#!/usr/bin/env bash
# Usage: build-appimage.sh [VERSION]. Run the resulting AppImage with 'setup'
# to register its desktop entry and point the user service at the AppImage.
set -euo pipefail
# shellcheck source=scripts/linux/package/common.sh
. "$(dirname -- "$0")/common.sh"
docker run --rm --user "$(id -u):$(id -g)" \
    -v "$REPO:/repo:ro" -v "$OUT:/out" \
    vizier-package-tools bash /repo/scripts/linux/package/assemble-appimage.sh "$VERSION"
echo "$OUT/Vizier-${VERSION}-x86_64.AppImage"
