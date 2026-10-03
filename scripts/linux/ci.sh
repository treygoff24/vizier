#!/usr/bin/env bash
# Linux CI entry point. Optional --filter supports bounded lane verification;
# CI omits it to run the complete suite. The portal mock always runs separately.
# Usage: scripts/linux/ci.sh [--filter SUITE] [CHECKOUT]
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
checkout=$(cd -- "$here/../.." && pwd)
filter=
if [[ "${1:-}" == --filter ]]; then
    [[ $# -ge 2 && -n "$2" ]] || { echo '--filter requires a suite' >&2; exit 64; }
    filter=$2
    shift 2
fi
[[ $# -le 1 ]] || { echo 'Usage: ci.sh [--filter SUITE] [CHECKOUT]' >&2; exit 64; }
if [[ $# == 1 ]]; then
    checkout=$(cd -- "$1" && pwd)
fi
[[ -f "$checkout/Package.swift" ]] || { echo "Missing Package.swift: $checkout" >&2; exit 64; }
command -v docker >/dev/null || { echo 'Docker is required for Linux CI' >&2; exit 69; }

# The small context contains no checkout, credentials, or host build artifacts.
# Docker reuses cached layers, including the signed toolchain download.
image=vizier-linux-ci:swift-6.4.0
cache_args=()
if docker image inspect "$image" >/dev/null 2>&1; then
    cache_args=(--cache-from "$image")
fi
docker build --build-arg BUILDKIT_INLINE_CACHE=1 "${cache_args[@]}" --tag "$image" "$here/ci"
docker run --rm --init --cap-drop=ALL --security-opt=no-new-privileges \
    --mount "type=bind,source=$checkout,target=/checkout,readonly" \
    --env "VIZIER_CI_FILTER=$filter" \
    "$image"
