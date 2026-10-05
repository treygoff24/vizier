#!/usr/bin/env bash
# Container-only assembler; invoked by build-deb.sh.
set -euo pipefail
version=$1
root=$(mktemp -d /out/deb.XXXXXX)
chmod 0755 "$root"
install -Dm0755 /out/vizier "$root/usr/bin/vizier"
install -d "$root/usr/share/vizier/sounds" "$root/usr/share/doc/vizier" "$root/DEBIAN"
install -m0644 /repo/Resources/Sounds/*.wav "$root/usr/share/vizier/sounds/"
install -Dm0644 /repo/Resources/linux/net.praxient.vizier.desktop "$root/usr/share/applications/net.praxient.vizier.desktop"
install -Dm0644 /repo/Resources/linux/vizier.service "$root/usr/lib/systemd/user/vizier.service"
sed -i 's|@VIZIER_BIN@|/usr/bin/vizier|g' "$root/usr/lib/systemd/user/vizier.service"
install -m0644 /repo/NOTICE /repo/LICENSE "$root/usr/share/doc/vizier/"
install -m0644 /repo/Sources/CCosmicFocus/LICENSE "$root/usr/share/doc/vizier/COSMIC-PROTOCOL-LICENSES"
cat > "$root/usr/share/doc/vizier/copyright" <<'EOF'
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: Vizier
Source: https://github.com/treygoff24/vizier

Files: *
Copyright: 2026 Trey Goff and the Vizier contributors
           VoiceInk contributors, primarily Prakash Joshi Pax
License: GPL-3
 On Debian systems the full GNU General Public License version 3 is in
 /usr/share/common-licenses/GPL-3. The upstream grant is version 3 only.
Comment: See NOTICE for individual upstream attribution and LICENSE for the
 complete license shipped with this package.

Files: Sources/CCosmicFocus/protocols/*
Copyright: 2018, 2020 Ilia Bozhinov
           2019 Christopher Billington
           2020 Isaac Freund
           2022, 2024 Victoria Brekenfeld
           2022 wb9688
           2023 i509VCB
License: HPND-sell-variant
 Permission to use, copy, modify, distribute, and sell this
 software and its documentation for any purpose is hereby granted
 without fee, provided that the above copyright notice appear in
 all copies and that both that copyright notice and this permission
 notice appear in supporting documentation, and that the name of
 the copyright holders not be used in advertising or publicity
 pertaining to distribution of the software without specific,
 written prior permission.  The copyright holders make no
 representations about the suitability of this software for any
 purpose.  It is provided "as is" without express or implied
 warranty.
 .
 THE COPYRIGHT HOLDERS DISCLAIM ALL WARRANTIES WITH REGARD TO THIS
 SOFTWARE, INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND
 FITNESS, IN NO EVENT SHALL THE COPYRIGHT HOLDERS BE LIABLE FOR ANY
 SPECIAL, INDIRECT OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN
 AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
 ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF
 THIS SOFTWARE.
Comment: See COSMIC-PROTOCOL-LICENSES for the individual notices.
EOF
cat > "$root/usr/share/doc/vizier/changelog" <<EOF
vizier ($version) unstable; urgency=medium

  * Package the Linux dictation daemon and command-line client.

 -- Vizier contributors <223498200+treygoff24@users.noreply.github.com>  Sat, 03 Oct 2026 00:00:00 +0000
EOF
gzip -9n "$root/usr/share/doc/vizier/changelog"
install -d "$root/usr/share/man/man1"
gzip -9nc /repo/scripts/linux/package/vizier.1 > "$root/usr/share/man/man1/vizier.1.gz"
# dpkg-shlibdeps uses Debian 13's package database and inspects the actual ELF.
# It also computes libc's symbol-version floor rather than assuming one.
mkdir -p "$root/debian"
printf 'Source: vizier\nSection: utils\nPriority: optional\nMaintainer: Vizier contributors <223498200+treygoff24@users.noreply.github.com>\n\nPackage: vizier\nArchitecture: amd64\nDescription: Dictation daemon and command-line client\n' > "$root/debian/control"
depends=$(cd "$root" && dpkg-shlibdeps -O -eusr/bin/vizier | sed -n 's/^shlibs:Depends=//p')
depends=$(printf '%s\n' "$depends" | sed -E 's/libcurl4t64 (\([^)]*\))/libcurl4t64 \1 | libcurl4 \1/')
[[ -n $depends ]] || { echo 'Could not derive ELF dependencies' >&2; exit 1; }
# Batch users may use older curl; live WebSockets require 8.11, so the version
# floor is a Recommends, avoiding exclusion of older batch-only installations.
cat > "$root/DEBIAN/control" <<EOF
Package: vizier
Version: $version
Architecture: amd64
Section: utils
Priority: optional
Maintainer: Vizier contributors <223498200+treygoff24@users.noreply.github.com>
Depends: $depends, libsystemd0, ca-certificates
Recommends: libcurl4t64 (>= 8.11) | libcurl4 (>= 8.11), pipewire-bin | pulseaudio-utils, libsecret-tools, xclip | wl-clipboard, xdotool | wtype, libnotify-bin
Homepage: https://github.com/treygoff24/vizier
Description: Dictation daemon and command-line client
 Record and transcribe takes with local Whisper or optional cloud engines.
 Includes a headless daemon and thin Linux desktop adapters.
EOF
printf '%s\n' "$depends, libsystemd0, ca-certificates" > /out/deb-dependencies.txt
# Packaging scratch is retained for inspection, outside the payload.
mv "$root/debian" "$root/../$(basename "$root").shlibdeps"
strip "$root/usr/bin/vizier"
artifact=$root.deb
dpkg-deb --root-owner-group --build "$root" "$artifact"
if command -v lintian >/dev/null; then
    lintian --allow-root "$artifact" > /out/lintian.txt 2>&1 || lint_rc=$?
    cat /out/lintian.txt
    # Warnings are reported; lintian errors are a build failure.
    if rg -q '^E:' /out/lintian.txt; then exit "${lint_rc:-1}"; fi
fi
mv "$artifact" "/out/vizier_${version}_amd64.deb"
