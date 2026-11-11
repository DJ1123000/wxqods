#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .work/tests
OUT=$(mktemp -d "$PWD/.work/tests/launchservices.XXXXXX")
BINARY=$OUT/WQLaunchServicesTests
cleanup() {
    rm -rf -- "$OUT"
}
trap cleanup EXIT
MACOS_SDK=$(xcrun --sdk macosx --show-sdk-path)
xcrun --sdk macosx clang -arch arm64 -fobjc-arc -fmodules -fmodules-cache-path="$OUT/modules-macos" -isysroot "$MACOS_SDK" \
    -Wall -Wextra -Werror -I. WQLaunchServices.m tests/WQLaunchServicesTests.m \
    -framework Foundation -o "$BINARY"
"$BINARY"
IOS_SDK=$(xcrun --sdk iphoneos --show-sdk-path)
MIN_OS=$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' Info.plist)
xcrun --sdk iphoneos clang -arch arm64 -fobjc-arc -fmodules -fmodules-cache-path="$OUT/modules-ios" -isysroot "$IOS_SDK" \
    -miphoneos-version-min="$MIN_OS" -Wall -Wextra -Werror -I. -fsyntax-only \
    WQLaunchServices.m tests/WQLaunchServicesTests.m
