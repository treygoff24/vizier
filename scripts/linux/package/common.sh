#!/usr/bin/env bash
# Shared host entry point. All generated files stay under package/out by default.
set -euo pipefail
PACKAGE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd -- "$PACKAGE_DIR/../../.." && pwd)
VERSION=${VERSION:-${1:-$(. "$REPO/VERSION" && echo "$MARKETING_VERSION")}}
[[ $VERSION =~ ^[0-9][A-Za-z0-9.+~:-]*$ ]] || { echo 'Invalid VERSION' >&2; exit 2; }
OUT=${OUT:-$PACKAGE_DIR/out}
mkdir -p "$OUT"
OUT=$(cd -- "$OUT" && pwd)
if [[ -z ${VIZIER_BINARY:-} ]]; then
    [[ -f /usr/include/wayland-client.h ]] || { echo 'Install libwayland-dev on the build host before building' >&2; exit 1; }
    # Swift 6.4's swiftbuild backend omits CoreFoundation/_CFURLSessionInterface
    # when statically linking Foundation. Native SwiftPM supplies those archives.
    # shellcheck disable=SC1091
    . "$HOME/.local/share/swiftly/env.sh"
    # The build host has libcurl.so.4 but lacks the development symlink. Make a
    # workspace-local linker alias; no headers or host installation are needed.
    curl_library=$(/sbin/ldconfig -p | awk '$1 == "libcurl.so.4" && /x86-64/ {print $NF; exit}')
    [[ -f $curl_library ]] || { echo 'Install libcurl4t64 or libcurl4 before building' >&2; exit 1; }
    mkdir -p "$OUT/link-libs"
    ln -sfn "$curl_library" "$OUT/link-libs/libcurl.so"
    testrun dictum l7b-package-release -- swift build --package-path "$REPO" \
        --build-system native -c release --product vizier --static-swift-stdlib -j 8 \
        -Xlinker "-L$OUT/link-libs" -Xlinker -z -Xlinker relro -Xlinker -z -Xlinker now
    bin_dir=$(swift build --package-path "$REPO" --build-system native -c release --show-bin-path)
    VIZIER_BINARY=$bin_dir/vizier
fi
[[ -x $VIZIER_BINARY ]] || { echo "Missing executable: $VIZIER_BINARY" >&2; exit 1; }
install -m 0755 "$VIZIER_BINARY" "$OUT/vizier"
readelf -d "$OUT/vizier" > "$OUT/readelf.txt"
ldd "$OUT/vizier" > "$OUT/ldd.txt"
if rg -q 'not found|libswift|libFoundation|libdispatch|libBlocksRuntime' "$OUT/ldd.txt"; then
    echo 'Binary has missing libraries or requires the Swift runtime; see out/ldd.txt' >&2
    exit 1
fi
docker build -t vizier-package-tools "$PACKAGE_DIR"
