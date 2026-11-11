#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=$(mktemp -d "${TMPDIR:-/tmp}/wqcore-tests.XXXXXX")
BINARY="$OUT/WQCoreTests"
cleanup() { rm -rf -- "$OUT"; }
trap cleanup EXIT
SDK=$(xcrun --sdk macosx --show-sdk-path)
printf 'building portable WQCore regression tests...\n'
xcrun --sdk macosx clang -fobjc-arc -fmodules -isysroot "$SDK" \
    -Wall -Wextra -Werror -I. WQCore.m tests/WQCoreTests.m \
    -framework Foundation -o "$BINARY"
printf 'running portable WQCore regression tests...\n'
"$BINARY"
