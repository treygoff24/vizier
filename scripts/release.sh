#!/usr/bin/env bash
# Produce a signed, notarized, stapled DMG and the matching Sparkle appcast entry in build/.
# It publishes nothing: uploading to GitHub Releases is a separate, deliberate step.
#
# Needs, from the maintainer's Mac:
#   VIZIER_SIGN_IDENTITY   a "Developer ID Application: ..." identity (name or SHA-1)
#   a notarytool keychain profile, created once with
#       xcrun notarytool store-credentials dictum-notary
#     (name it differently with VIZIER_NOTARY_PROFILE). Credentials never pass through this script.
#   Sparkle's EdDSA private key in the login Keychain under account "dictum" (VIZIER_SPARKLE_ACCOUNT),
#     made once with Sparkle's generate_keys --account dictum.
# Vizier was called Dictum until 2026-10-03. The default profile and key account keep the names they
# were created under, and each VIZIER_ variable falls back to its older DICTUM_ name.
#
# scripts/release.sh --skip-notarize is a local dry run: it signs everything but skips notarization,
# stapling, and the Gatekeeper check, and names every output "NOT-NOTARIZED" so it cannot be mistaken
# for a release. The signing mode, version, and build number come from build-app.sh and VERSION.
#
# Two checks guard what Sparkle will do with the release (scripts/release-checks.sh):
#   - BUILD_NUMBER must be greater than the last published build, read from the live feed at SUFeedURL.
#     While nothing is published there (HTTP 404) there is no earlier build to compare against, and the
#     script says so; any other fetch failure stops a release. A dry run warns instead of stopping.
#   - After sign_update, the DMG's EdDSA signature must verify against SUPublicEDKey in
#     Resources/Info.plist (the key installed copies trust), and the built app must carry that same key.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo"
# shellcheck source=release-checks.sh
source "$repo/scripts/release-checks.sh"

notarize=1
for arg in "$@"; do
  case "$arg" in
    --skip-notarize) notarize=0 ;;
    *) echo "usage: scripts/release.sh [--skip-notarize]" >&2; exit 64 ;;
  esac
done

identity=${VIZIER_SIGN_IDENTITY:-${DICTUM_SIGN_IDENTITY:-}}
profile=${VIZIER_NOTARY_PROFILE:-${DICTUM_NOTARY_PROFILE:-dictum-notary}}
account=${VIZIER_SPARKLE_ACCOUNT:-${DICTUM_SPARKLE_ACCOUNT:-dictum}}
[ -n "$identity" ] || { echo "release.sh: set VIZIER_SIGN_IDENTITY to your Developer ID Application identity" >&2; exit 1; }

# shellcheck source=../VERSION
source "$repo/VERSION"
app="$repo/build/Vizier.app"
suffix=""; [ "$notarize" = 1 ] || suffix="-NOT-NOTARIZED"
dmg="$repo/build/Vizier-$MARKETING_VERSION$suffix.dmg"
appcast="$repo/build/appcast$suffix.xml"

# Step 4 below needs the notary profile. Check it now so a missing profile fails before a ten-minute build,
# with the one command that creates it.
if [ "$notarize" = 1 ]; then
  if ! xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1; then
    echo "release.sh: step 4 (notarize) cannot run: keychain profile \"$profile\" is missing or rejected." >&2
    echo "  Create it once: xcrun notarytool store-credentials \"$profile\"" >&2
    echo "  Or rehearse without notarizing: scripts/release.sh --skip-notarize" >&2
    exit 1
  fi
fi

# Sparkle offers an update only when its build number is greater than the installed one: check it now,
# before the build, against the last build the published feed lists.
feed=$(plutil -extract SUFeedURL raw -o - "$repo/Resources/Info.plist")
public_key=$(plutil -extract SUPublicEDKey raw -o - "$repo/Resources/Info.plist")
if ! last_build=$(fetch_last_released_build "$feed") || ! require_newer_build "$BUILD_NUMBER" "$last_build"; then
  [ "$notarize" = 1 ] && exit 1
  echo "release.sh: continuing the dry run anyway; a release would stop here." >&2
fi

# Steps 1 and 2: build release, then sign inside-out (Sparkle's XPC services and helpers, Sparkle.framework,
# the app) with Developer ID, hardened runtime, and a timestamp. build-app.sh does both when the identity is set.
echo "== 1-2. build and sign"
"$repo/scripts/build-app.sh"
codesign --verify --deep --strict "$app"
# Privacy audit of the built app (private script, absent from the public export: skipped there).
[ ! -x "$repo/scripts/release-audit.sh" ] || "$repo/scripts/release-audit.sh" "$app"
# The build resolved the package, so Sparkle's tools are now on disk (a clean checkout has none before this).
sign_update=$(find "$repo/.build/artifacts" -type f -name sign_update -path '*/bin/*' -not -path '*old_dsa*' -print -quit)
[ -x "$sign_update" ] || { echo "release.sh: Sparkle's sign_update not found under .build/artifacts; run swift package resolve" >&2; exit 1; }
flags=$(codesign -dv "$app" 2>&1 | grep -E '^CodeDirectory' || true)
case "$flags" in *runtime*) ;; *) echo "release.sh: the app is not signed with hardened runtime" >&2; exit 1 ;; esac
app_key=$(plutil -extract SUPublicEDKey raw -o - "$app/Contents/Info.plist")
[ "$app_key" = "$public_key" ] || { echo "release.sh: the built app's SUPublicEDKey differs from Resources/Info.plist" >&2; exit 1; }

# Step 3: the DMG, with an Applications shortcut, signed.
echo "== 3. DMG"
# Temp state every exit path cleans up: the DMG staging folder, a read-only mount, and the notary result.
stage="" mount="" result=""
cleanup() {
  [ -z "$mount" ] || hdiutil detach "$mount" -force >/dev/null 2>&1 || true
  [ -z "$result" ] || rm -f -- "$result"
  [ -z "$stage" ] || rm -rf -- "$stage"
}
trap cleanup EXIT
stage=$(mktemp -d "${TMPDIR:-/tmp}/vizier-dmg.XXXXXX")
ditto "$app" "$stage/Vizier.app"
ln -s /Applications "$stage/Applications"
cp "$repo/LICENSE" "$repo/NOTICE" "$repo/THIRD-PARTY-LICENSES" "$stage/"
rm -f -- "$dmg"
hdiutil create -volname "Vizier" -srcfolder "$stage" -format UDZO -ov "$dmg" >/dev/null
codesign --force --timestamp --sign "$identity" "$dmg"
codesign --verify --strict --verbose=2 "$dmg"

if [ "$notarize" = 1 ]; then
  # Step 4: notarize and require Accepted.
  echo "== 4. notarize (waits for Apple)"
  result=$(mktemp "${TMPDIR:-/tmp}/vizier-notary.XXXXXX")
  xcrun notarytool submit "$dmg" --wait --keychain-profile "$profile" --output-format plist >"$result"
  status=$(plutil -extract status raw -o - "$result")
  id=$(plutil -extract id raw -o - "$result")
  if [ "$status" != "Accepted" ]; then
    echo "release.sh: notarization returned \"$status\" (submission $id); Apple's log:" >&2
    xcrun notarytool log "$id" --keychain-profile "$profile" >&2 || true
    exit 1
  fi
  # Step 5: staple and validate. Stapling rewrites the DMG, so it must come before signing the update.
  echo "== 5. staple and validate"
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
  # Gatekeeper's verdict on the app a user will actually run: the copy inside the final DMG.
  mount=$(mktemp -d "${TMPDIR:-/tmp}/vizier-mount.XXXXXX")
  hdiutil attach -readonly -nobrowse -mountpoint "$mount" "$dmg" >/dev/null
  spctl --assess --type execute --verbose=2 "$mount/Vizier.app"
  hdiutil detach "$mount" >/dev/null
  rmdir "$mount"
  mount=""
else
  echo "== 4-5. notarize, staple: SKIPPED (--skip-notarize). $dmg is NOT notarized and must not be released."
fi

# Step 6: sign the update archive (the final DMG) with Sparkle's EdDSA key, verify that signature against
# the public key the app ships, and write the appcast entry.
echo "== 6. Sparkle signature and appcast entry"
signature=$("$sign_update" --account "$account" "$dmg")   # prints: sparkle:edSignature="..." length="..."
verify_update_signature "$dmg" "$signature" "$public_key" || exit 1
# The download URL sits beside the feed: <releases>/download/v<version>/<dmg>, derived from SUFeedURL.
releases=${feed%/latest/download/*}
url="$releases/download/v$MARKETING_VERSION/$(basename "$dmg")"
min_os=$(plutil -extract LSMinimumSystemVersion raw -o - "$repo/Resources/Info.plist")
pub_date=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")
{
  echo '<?xml version="1.0" encoding="utf-8"?>'
  echo '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
  [ "$notarize" = 1 ] || echo '  <!-- NOT NOTARIZED: a local dry run. Do not publish. -->'
  echo '  <channel>'
  echo '    <title>Vizier</title>'
  echo '    <item>'
  echo "      <title>Version $MARKETING_VERSION</title>"
  echo "      <pubDate>$pub_date</pubDate>"
  echo "      <sparkle:version>$BUILD_NUMBER</sparkle:version>"
  echo "      <sparkle:shortVersionString>$MARKETING_VERSION</sparkle:shortVersionString>"
  echo "      <sparkle:minimumSystemVersion>$min_os</sparkle:minimumSystemVersion>"
  echo "      <enclosure url=\"$url\" $signature type=\"application/octet-stream\"/>"
  echo '    </item>'
  echo '  </channel>'
  echo '</rss>'
} >"$appcast"
xmllint --noout "$appcast"
# The same audit on what actually ships: the final DMG and its appcast.
[ ! -x "$repo/scripts/release-audit.sh" ] || "$repo/scripts/release-audit.sh" "$dmg" "$appcast"

echo
echo "dmg:     $dmg"
echo "appcast: $appcast"
[ "$notarize" = 1 ] && echo "Nothing was published. Upload both to the GitHub release when ready." \
  || echo "NOT NOTARIZED: dry run only."
