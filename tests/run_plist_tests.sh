#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=$(mktemp -d "${TMPDIR:-/tmp}/wq-plist-tests.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
SDK=$(xcrun --sdk macosx --show-sdk-path)
xcrun --sdk macosx clang -fobjc-arc -fmodules -isysroot "$SDK" \
    -Wall -Wextra -Werror -I. WQCore.m tests/WQCoreTests.m -o "$OUT/WQCoreTests"
xcrun --sdk macosx clang -fobjc-arc -fmodules -isysroot "$SDK" \
    -Wall -Wextra -Werror -I. tests/WQPlistEditorSupportTests.m -o "$OUT/WQPlistEditorSupportTests"
"$OUT/WQCoreTests"
"$OUT/WQPlistEditorSupportTests"
