#!/usr/bin/env bash
# Usage: build-appimage.sh [VERSION]. Hotkey portals need the .desktop installed
# in the user's applications directory; AppImage does not install it. Vizier
# setup must do that (currently an application follow-up outside this lane).
set -euo pipefail
# shellcheck source=scripts/linux/package/common.sh
. "$(dirname -- "$0")/common.sh"
docker run --rm --user "$(id -u):$(id -g)" \
    -v "$REPO:/repo:ro" -v "$OUT:/out" \
    vizier-package-tools bash /repo/scripts/linux/package/assemble-appimage.sh "$VERSION"
echo "$OUT/Vizier-${VERSION}-x86_64.AppImage"
