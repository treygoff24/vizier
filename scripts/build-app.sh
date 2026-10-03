#!/usr/bin/env bash
# Build, bundle, and sign build/Vizier.app.
#
# Signing has two modes, chosen by whether VIZIER_SIGN_IDENTITY is set:
#   unset  ad-hoc ("-"), no hardened runtime, no timestamp (VIZIER_SIGN_IDENTITY=- means the same). This is the contributor build. It runs on
#          this Mac and loads the ad-hoc-signed Sparkle framework, which hardened runtime's library
#          validation would refuse.
#   set    that Developer ID identity (a name or SHA-1 from `security find-identity -v -p codesigning`),
#          with hardened runtime and a secure timestamp. This is the release build; the timestamp needs
#          network access.
# Keep the bundle id (and, for release builds, the identity) stable: macOS ties the Microphone and
# Accessibility grants to them, so changing either re-prompts.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
app="$repo/build/Vizier.app"
# DICTUM_SIGN_IDENTITY, the name from before the rename (2026-10-03), still works.
identity=${VIZIER_SIGN_IDENTITY:-${DICTUM_SIGN_IDENTITY:-}}
# "-" is codesign's name for the ad-hoc identity: take the ad-hoc path, not Developer ID with runtime.
if [ "$identity" = "-" ]; then identity=""; fi

# The version comes from one place: VERSION.
# shellcheck source=../VERSION
source "$repo/VERSION"
: "${MARKETING_VERSION:?VERSION must set MARKETING_VERSION}" "${BUILD_NUMBER:?VERSION must set BUILD_NUMBER}"

swift build --package-path "$repo" -c release --product Vizier
bin_dir=$(swift build --package-path "$repo" -c release --show-bin-path)
bin="$bin_dir/Vizier"
test -x "$bin" || { echo "missing binary: $bin" >&2; exit 1; }
# SwiftPM unpacks the Sparkle release zip once; its binary framework is the one we embed.
sparkle=$(find "$repo/.build/artifacts" -type d -name Sparkle.framework -path '*macos-arm64_x86_64*' -print -quit)
test -d "$sparkle" || { echo "missing Sparkle.framework under .build/artifacts; run swift package resolve" >&2; exit 1; }

rm -rf -- "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources/Fonts" "$app/Contents/Resources/Sounds"
cp "$bin" "$app/Contents/MacOS/Vizier"
# The linker's debug-map entries (OSO/SO) hold the absolute path of every object file and source
# directory on the build machine. Strip them from the shipped copy (the build output stays intact);
# global symbols stay for crash reports. scripts/release-audit.sh checks the result.
strip -S "$app/Contents/MacOS/Vizier"
# ditto keeps the framework's Versions/Current symlinks; cp -R would break the signature seal.
ditto "$sparkle" "$app/Contents/Frameworks/Sparkle.framework"
cp "$repo/Resources/Info.plist" "$app/Contents/Info.plist"
cp "$repo/Resources/Vizier.icns" "$app/Contents/Resources/Vizier.icns"
cp "$repo"/Resources/Fonts/* "$app/Contents/Resources/Fonts/"
cp "$repo"/Resources/Sounds/*.wav "$app/Contents/Resources/Sounds/"
cp "$repo/LICENSE" "$repo/NOTICE" "$repo/THIRD-PARTY-LICENSES" "$app/Contents/Resources/"
plutil -replace CFBundleShortVersionString -string "$MARKETING_VERSION" "$app/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" >/dev/null

# The binary finds Sparkle at ../Frameworks relative to itself. The linker setting in Package.swift
# normally adds this; add it here if it is missing so the bundle never depends on that.
if ! otool -l "$app/Contents/MacOS/Vizier" | grep 'path @executable_path/../Frameworks ' >/dev/null; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$app/Contents/MacOS/Vizier"
fi

if [ -n "$identity" ]; then
  sign_flags=(--force --sign "$identity" --options runtime --timestamp)
  mode="Developer ID, hardened runtime, timestamped"
else
  sign_flags=(--force --sign -)
  mode="ad-hoc (no hardened runtime)"
fi

# Sign inside-out: every nested code object before the bundle that contains it. Sparkle's helpers keep
# the entitlements they shipped with; the app gets Vizier's own.
sparkle_b="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
for nested in \
  "$sparkle_b/XPCServices/Installer.xpc" \
  "$sparkle_b/XPCServices/Downloader.xpc" \
  "$sparkle_b/Autoupdate" \
  "$sparkle_b/Updater.app"; do
  [ -e "$nested" ] && codesign "${sign_flags[@]}" --preserve-metadata=entitlements "$nested"
done
codesign "${sign_flags[@]}" "$app/Contents/Frameworks/Sparkle.framework"
codesign "${sign_flags[@]}" --entitlements "$repo/Resources/Vizier.entitlements" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
if [ -n "$identity" ]; then
  # A release must carry hardened runtime on the app and every nested code object; fail rather than ship without.
  for signed in "$app" "$app/Contents/Frameworks/Sparkle.framework" "$sparkle_b/XPCServices/Installer.xpc" "$sparkle_b/Updater.app"; do
    codesign -dv "$signed" 2>&1 | grep 'flags=.*(runtime)' >/dev/null \
      || { echo "build-app.sh: $signed is not signed with hardened runtime" >&2; exit 1; }
  done
fi
echo "built $app: $MARKETING_VERSION ($BUILD_NUMBER), $mode"
