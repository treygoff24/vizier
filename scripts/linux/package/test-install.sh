#!/usr/bin/env bash
# Clean installs: no Swift toolchain, no host home or ~/.local/bin mounted.
# Usage: test-install.sh [VERSION]; build both artifacts first.
set -euo pipefail
package_dir=$(cd -- "$(dirname -- "$0")" && pwd)
version=${VERSION:-${1:-$(. "$package_dir/../../../VERSION" && echo "$MARKETING_VERSION")}}
out=${OUT:-$package_dir/out}
out=$(cd -- "$out" && pwd)
[[ -f $out/vizier_${version}_amd64.deb && -f $out/Vizier-${version}-x86_64.AppImage ]] || {
    echo 'Build the deb and AppImage before testing' >&2; exit 1;
}
docker pull debian:trixie
ubuntu=ubuntu:26.04
if ! docker pull "$ubuntu"; then
    ubuntu=ubuntu:25.10
    echo 'Ubuntu 26.04 unavailable; testing Ubuntu 25.10 instead' >&2
    docker pull "$ubuntu"
fi
for image in debian:trixie "$ubuntu"; do
    mode=deb
    [[ $image != debian:trixie ]] || mode=both
    docker run --rm -v "$package_dir:/opt/package:ro" -v "$out:/artifacts:ro" \
        "$image" bash /opt/package/install-in-container.sh "$version" "$mode"
done
