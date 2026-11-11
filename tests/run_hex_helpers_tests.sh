#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=$(mktemp -d "${TMPDIR:-/tmp}/wq-hex-helpers.XXXXXX")
cleanup() {
    rm -rf "$OUT"
}
trap cleanup EXIT
SDK=$(xcrun --sdk macosx --show-sdk-path)
xcrun --sdk macosx clang -fobjc-arc -fmodules -isysroot "$SDK" \
    -Wall -Wextra -Werror -I. tests/WQHexViewerHelpersTests.m \
    -framework Foundation -o "$OUT/WQHexViewerHelpersTests"
"$OUT/WQHexViewerHelpersTests"
