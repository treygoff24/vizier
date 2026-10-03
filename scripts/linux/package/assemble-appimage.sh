#!/usr/bin/env bash
set -euo pipefail
version=$1
appdir=$(mktemp -d /out/Vizier.AppDir.XXXXXX)
chmod 0755 "$appdir"
install -Dm0755 /out/vizier "$appdir/usr/bin/vizier"
install -d "$appdir/usr/share/vizier/sounds" "$appdir/usr/share/doc/vizier"
install -m0644 /repo/Resources/Sounds/*.wav "$appdir/usr/share/vizier/sounds/"
install -m0644 /repo/NOTICE /repo/LICENSE "$appdir/usr/share/doc/vizier/"
install -m0644 /repo/Resources/linux/net.praxient.vizier.desktop "$appdir/net.praxient.vizier.desktop"
sed -i 's/^Icon=.*/Icon=vizier/' "$appdir/net.praxient.vizier.desktop"
convert /repo/Resources/AppIcon-1024.png -resize 256x256 "$appdir/vizier.png"
ln -s vizier.png "$appdir/.DirIcon"
cat > "$appdir/AppRun" <<'EOF'
#!/bin/sh
set -eu
appdir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$appdir/usr/bin/vizier" "$@"
EOF
chmod 0755 "$appdir/AppRun"
strip "$appdir/usr/bin/vizier"
# Versioned release, pinned SHA-256 from its GitHub release asset digest.
tool=/out/appimagetool-1.9.1-x86_64.AppImage
curl --fail --location --retry 3 -o "$tool" 'https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage'
printf '%s  %s\n' 'ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0' "$tool" | sha256sum --check -
chmod 0755 "$tool"
# Pin the runtime too: appimagetool otherwise downloads mutable, unchecked bytes.
# type2-runtime continuous asset from commit 8f39b89e2ac31e1640b3d3f7e9a5108e6ce805fa.
# A moved release fails checksum verification; update the pin deliberately.
runtime=/out/runtime-x86_64
curl --fail --location --retry 3 -o "$runtime" 'https://github.com/AppImage/type2-runtime/releases/download/continuous/runtime-x86_64'
printf '%s  %s\n' '156f4bdbde9c52d01814600013e0a273f0118dc2de98975f3c8c63427ec79074' "$runtime" | sha256sum --check -
artifact=$appdir.AppImage
ARCH=x86_64 "$tool" --appimage-extract-and-run --runtime-file "$runtime" \
    --mksquashfs-opt -processors --mksquashfs-opt 8 "$appdir" "$artifact"
mv "$artifact" "/out/Vizier-${version}-x86_64.AppImage"
# This minimal AppImage carries static Swift/Foundation, not distro libraries.
# Exact host library requirements are written alongside it by common.sh.
