# shellcheck shell=bash
# The checks release.sh makes around a release: the build number must go past the last published one,
# and the update archive's EdDSA signature must verify against the key the app ships (SUPublicEDKey).
# Sourced by release.sh and by scripts/test-release-checks.sh; it only defines functions.

release_checks_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# last_released_build <appcast.xml>: prints the highest sparkle:version among the feed's items (the
# element, or the older enclosure attribute), or nothing when the feed lists no items. Fails on an item
# whose version is not a whole number, since then nothing can be compared.
last_released_build() {
  local feed=$1 count i v max=""
  count=$(xmllint --xpath 'count(//item)' "$feed") || { echo "release.sh: $feed is not a readable appcast" >&2; return 1; }
  for ((i = 1; i <= count; i++)); do
    v=$(xmllint --xpath "string((//item)[$i]/*[local-name()='version'])" "$feed")
    [ -n "$v" ] || v=$(xmllint --xpath "string((//item)[$i]/enclosure/@*[local-name()='version'])" "$feed")
    [[ $v =~ ^[0-9]+$ ]] || { echo "release.sh: appcast item $i has no whole-number sparkle:version (\"$v\")" >&2; return 1; }
    if [ -z "$max" ] || [ "$((10#$v))" -gt "$((10#$max))" ]; then max=$v; fi
  done
  printf '%s\n' "$max"
}

# fetch_last_released_build <feed-url>: the last published build, read from the live feed (what every
# installed copy compares against). HTTP 404 means nothing is published yet: it prints nothing and says
# so. Any other failure fails, so a network error never reads as "first release".
fetch_last_released_build() {
  local url=$1 body code rc=0
  body=$(mktemp "${TMPDIR:-/tmp}/vizier-feed.XXXXXX")
  if ! code=$(curl -sS -L --max-time 60 -o "$body" -w '%{http_code}' "$url"); then
    rm -f -- "$body"
    echo "release.sh: cannot fetch the published appcast $url" >&2
    return 1
  fi
  case "$code" in
    200) last_released_build "$body" || rc=1 ;;
    404) echo "release.sh: no appcast is published at $url yet; no earlier build to compare against" >&2 ;;
    *) echo "release.sh: fetching the published appcast $url returned HTTP $code" >&2; rc=1 ;;
  esac
  rm -f -- "$body"
  return "$rc"
}

# require_newer_build <new> <last>: Sparkle offers an update only when its build number is greater than
# the installed one, so a release whose BUILD_NUMBER does not exceed the last published build would
# never reach anyone (or, with a reused number, would collide with it). An empty <last> passes.
require_newer_build() {
  local new=$1 last=$2
  [[ $new =~ ^[0-9]+$ ]] || { echo "release.sh: BUILD_NUMBER \"$new\" is not a whole number" >&2; return 1; }
  [ -n "$last" ] || return 0
  [[ $last =~ ^[0-9]+$ ]] || { echo "release.sh: the last released build \"$last\" is not a whole number" >&2; return 1; }
  if [ "$((10#$new))" -le "$((10#$last))" ]; then
    echo "release.sh: BUILD_NUMBER $new is not greater than the last released build $last; raise it in VERSION" >&2
    return 1
  fi
}

# verify_update_signature <file> <sign_update output> <base64 public key>: the attributes sign_update
# printed (sparkle:edSignature="..." length="...") describe <file>, and the signature verifies against
# <public key>. sign_update --verify would only check the Keychain key against itself; this checks the
# key the installed app will use.
verify_update_signature() {
  local file=$1 attrs=$2 key=$3 sig length size
  sig=$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"$attrs")
  length=$(sed -n 's/.*length="\([0-9]*\)".*/\1/p' <<<"$attrs")
  if [ -z "$sig" ] || [ -z "$length" ]; then
    echo "release.sh: sign_update gave no signature: $attrs" >&2
    return 1
  fi
  size=$(stat -f %z "$file")
  [ "$length" = "$size" ] || { echo "release.sh: sign_update reported length $length but $file is $size bytes" >&2; return 1; }
  if ! swift "$release_checks_dir/verify-sparkle-signature.swift" "$file" "$sig" "$key" >&2; then
    echo "release.sh: $file is not signed by the app's SUPublicEDKey; the Keychain key used to sign it is not the one the app trusts" >&2
    return 1
  fi
}
