#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .work/tests
OUT=$(mktemp -d "$PWD/.work/tests/apps.XXXXXX")
BINARY=$OUT/WQAppsSupportTests
cleanup() {
    rm -rf -- "$OUT"
}
trap cleanup EXIT
SDK=$(xcrun --sdk macosx --show-sdk-path)
xcrun --sdk macosx clang -fobjc-arc -fmodules -fmodules-cache-path="$OUT/modules-macos" -isysroot "$SDK" \
    -Wall -Wextra -Werror -I. tests/WQAppsSupportTests.m \
    -framework Foundation -o "$BINARY"
"$BINARY"
