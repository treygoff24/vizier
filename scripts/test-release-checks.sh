#!/usr/bin/env bash
# Tests scripts/release-checks.sh without releasing anything: the build-number rule, the appcast parse,
# the feed fetch (with a stub curl on PATH), and the EdDSA check with a throwaway key made here. It never
# reads the real Sparkle key from the Keychain. Needs Sparkle's sign_update under .build/artifacts
# (swift package resolve) and the Swift toolchain.
#
#   scripts/test-release-checks.sh
set -uo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=release-checks.sh
source "$repo/scripts/release-checks.sh"

pass=0 failed=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failed=$((failed + 1)); echo "FAIL $1"; }
# expect_ok <name> <command...> / expect_fail <name> <command...>
expect_ok() { local name=$1; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }
expect_fail() { local name=$1; shift; if "$@" >/dev/null 2>&1; then bad "$name"; else ok "$name"; fi; }
# expect_output <name> <expected stdout> <command...>: succeeds and prints exactly <expected>.
expect_output() {
  local name=$1 want=$2 got; shift 2
  if got=$("$@" 2>/dev/null) && [ "$got" = "$want" ]; then ok "$name"; else bad "$name (got \"${got:-}\", want \"$want\")"; fi
}

work=$(mktemp -d "${TMPDIR:-/tmp}/vizier-release-checks.XXXXXX")
trap 'rm -rf -- "$work"' EXIT

# --- require_newer_build
expect_ok     "a build above the last released one passes" require_newer_build 2 1
expect_fail   "the same build number is refused" require_newer_build 1 1
expect_fail   "a lower build number is refused" require_newer_build 1 2
expect_ok     "builds compare as numbers, not text (10 > 9)" require_newer_build 10 9
expect_fail   "builds compare as numbers, not text (9 < 10)" require_newer_build 9 10
expect_ok     "no recorded release leaves nothing to compare" require_newer_build 1 ""
# Shell arithmetic would evaluate these (1+1 is 2, 2-1 is 1), so only the whole-number check refuses them.
expect_fail   "a non-numeric BUILD_NUMBER is refused" require_newer_build "1+1" 1
expect_fail   "a non-numeric last build is refused" require_newer_build 3 "2-1"

# --- last_released_build
appcast() { # appcast <file> <item xml...>
  local file=$1; shift
  {
    echo '<?xml version="1.0" encoding="utf-8"?>'
    echo '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Vizier</title>'
    printf '%s\n' "$@"
    echo '</channel></rss>'
  } >"$file"
}
appcast "$work/two.xml" '<item><sparkle:version>12</sparkle:version></item>' '<item><sparkle:version>3</sparkle:version></item>'
expect_output "the highest version among the items, as a number" 12 last_released_build "$work/two.xml"
appcast "$work/attr.xml" '<item><enclosure url="u" sparkle:version="7" length="1"/></item>'
expect_output "the older enclosure attribute form is read" 7 last_released_build "$work/attr.xml"
appcast "$work/empty.xml"
expect_output "a feed with no items has no last build" "" last_released_build "$work/empty.xml"
appcast "$work/text.xml" '<item><sparkle:version>1.0b</sparkle:version></item>'
expect_fail   "a non-numeric item version is an error" last_released_build "$work/text.xml"

# --- fetch_last_released_build, against a stub curl that answers with STUB_CODE and STUB_BODY
mkdir -p "$work/bin"
cat >"$work/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac; done
[ "${STUB_EXIT:-0}" = 0 ] || exit "$STUB_EXIT"
[ -z "${STUB_BODY:-}" ] || cp "$STUB_BODY" "$out"
printf '%s' "$STUB_CODE"
EOF
chmod +x "$work/bin/curl"
fetch() { PATH="$work/bin:$PATH" fetch_last_released_build "https://example.invalid/appcast.xml"; }
STUB_CODE=200 STUB_BODY="$work/two.xml" expect_output "a published feed gives its last build" 12 fetch
STUB_CODE=404 STUB_BODY="" expect_output "nothing published (404) gives no last build" "" fetch
STUB_CODE=500 STUB_BODY="" expect_fail "any other HTTP status fails" fetch
STUB_CODE=000 STUB_EXIT=6 STUB_BODY="" expect_fail "a network failure fails, never reads as a first release" fetch

# --- verify_update_signature, with a throwaway key pair (never the real one)
sign_update=$(find "$repo/.build/artifacts" -type f -name sign_update -path '*/bin/*' -not -path '*old_dsa*' -print -quit)
if [ -z "$sign_update" ] || [ ! -x "$sign_update" ]; then
  bad "Sparkle's sign_update is not under .build/artifacts; run swift package resolve"
else
  cat >"$work/keys.swift" <<'EOF'
import CryptoKit
let key = Curve25519.Signing.PrivateKey()
print(key.rawRepresentation.base64EncodedString())
print(key.publicKey.rawRepresentation.base64EncodedString())
EOF
  swift "$work/keys.swift" >"$work/keys"
  sed -n 1p "$work/keys" >"$work/private-key"
  throwaway_public=$(sed -n 2p "$work/keys")
  app_public=$(plutil -extract SUPublicEDKey raw -o - "$repo/Resources/Info.plist")
  head -c 200000 /dev/urandom >"$work/update.dmg"
  attrs=$("$sign_update" --ed-key-file "$work/private-key" "$work/update.dmg")
  case "$attrs" in *sparkle:edSignature=*length=*) ok "sign_update signed with the throwaway key" ;; *) bad "sign_update output: $attrs" ;; esac

  expect_ok   "a signature by the matching key verifies" verify_update_signature "$work/update.dmg" "$attrs" "$throwaway_public"
  expect_fail "a signature by another key than SUPublicEDKey is refused" verify_update_signature "$work/update.dmg" "$attrs" "$app_public"
  cp "$work/update.dmg" "$work/flipped.dmg"
  printf '\x00\x01' | dd of="$work/flipped.dmg" bs=1 seek=1000 conv=notrunc 2>/dev/null
  if cmp -s "$work/update.dmg" "$work/flipped.dmg"; then bad "precondition: the flipped copy differs"; else ok "precondition: the flipped copy differs"; fi
  expect_fail "a same-length file with changed bytes is refused" verify_update_signature "$work/flipped.dmg" "$attrs" "$throwaway_public"
  wrong_length=$(sed 's/length="[0-9]*"/length="1"/' <<<"$attrs")
  expect_fail "a valid signature with a length that does not match the file is refused" \
    verify_update_signature "$work/update.dmg" "$wrong_length" "$throwaway_public"
  expect_fail "output with no signature is refused" verify_update_signature "$work/update.dmg" "error: no key" "$throwaway_public"
fi

echo "$pass passed, $failed failed"
[ "$failed" = 0 ]
