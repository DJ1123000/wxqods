#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Generated compiler output stays inside this worktree; fixtures use UUID temp paths.
OUT=.work/access-tests
mkdir -p "$OUT/tmp"
export TMPDIR="$PWD/$OUT/tmp/"
SDK=$(xcrun --sdk macosx --show-sdk-path)
xcrun --sdk macosx clang -fobjc-arc -fmodules -fmodules-cache-path="$OUT/ModuleCache" -isysroot "$SDK" \
    -Wall -Wextra -Werror -I. tests/WQAccessSafetyTests.m \
    -framework Foundation -o "$OUT/WQAccessSafetyTests"
"$OUT/WQAccessSafetyTests"
xcrun --sdk macosx clang -fobjc-arc -fmodules -fmodules-cache-path="$OUT/ModuleCache" -isysroot "$SDK" \
    -Wall -Wextra -Werror -I. tests/WQAccessMutationTests.m WQCore.m \
    -framework Foundation -o "$OUT/WQAccessMutationTests"
"$OUT/WQAccessMutationTests"
xcrun --sdk macosx clang -fobjc-arc -fmodules -fmodules-cache-path="$OUT/ModuleCache" -isysroot "$SDK" \
    -Wall -Wextra -Werror -I. tests/WQAccessTreeTests.m WQCore.m \
    -framework Foundation -o "$OUT/WQAccessTreeTests"
"$OUT/WQAccessTreeTests"
xcrun --sdk macosx clang -fobjc-arc -fmodules -fmodules-cache-path="$OUT/ModuleCache" -isysroot "$SDK" \
    -Wall -Wextra -Werror -I. tests/WQAccessCopyTests.m WQCore.m \
    -framework Foundation -o "$OUT/WQAccessCopyTests"
"$OUT/WQAccessCopyTests"
