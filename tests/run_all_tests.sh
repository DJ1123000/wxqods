#!/usr/bin/env bash
# All host-side fixtures are disposable; no iOS app/container operation is run.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
mkdir -p "$ROOT/.work/tests"
OUT=$(mktemp -d "$ROOT/.work/tests/all.XXXXXX")
mkdir -p "$OUT/fixtures"
export TMPDIR="$OUT/fixtures/"
export PYTHONDONTWRITEBYTECODE=1
MAC_SDK=$(xcrun --sdk macosx --show-sdk-path)
ASAN_FLAG=""
if [[ "${WQ_ASAN:-0}" == "1" ]]; then
    ASAN_FLAG="-fsanitize=address -fno-omit-frame-pointer"
    export ASAN_OPTIONS="detect_leaks=0"
fi

compile_run() {
    local name=$1
    shift
    printf '\n== %s ==\n' "$name"
    xcrun --sdk macosx clang -fobjc-arc -fmodules -fmodules-cache-path="$OUT/modules-macos" \
        -isysroot "$MAC_SDK" -Wall -Wextra -Werror $ASAN_FLAG -I. "$@" \
        -framework Foundation -o "$OUT/$name" > "$OUT/$name-build.log" 2>&1 || {
            cat "$OUT/$name-build.log" >&2
            return 1
        }
    "$OUT/$name" > "$OUT/$name-run.log" 2>&1 || {
        cat "$OUT/$name-run.log" >&2
        return 1
    }
    tail -3 "$OUT/$name-run.log"
}

compile_run WQCoreTests WQCore.m tests/WQCoreTests.m
compile_run WQAccessSafetyTests tests/WQAccessSafetyTests.m
compile_run WQAccessMutationTests tests/WQAccessMutationTests.m WQCore.m
compile_run WQAccessTreeTests tests/WQAccessTreeTests.m WQCore.m
compile_run WQAccessMeasureTests tests/WQAccessMeasureTests.m WQCore.m
compile_run WQAccessCopyTests tests/WQAccessCopyTests.m WQCore.m
compile_run WQAppsCopyTests tests/WQAppsCopyTests.m WQCore.m
compile_run WQAppsSupportTests tests/WQAppsSupportTests.m
compile_run WQCacheSafetyTests tests/WQCacheSafetyTests.m
compile_run WQPlistEditorSupportTests tests/WQPlistEditorSupportTests.m
compile_run WQHexViewerHelpersTests tests/WQHexViewerHelpersTests.m
compile_run WQArchiveTests WQArchive.m tests/WQArchiveTests.m -lz
compile_run WQOperationTests WQOperation.m tests/WQOperationTests.m
compile_run WQLaunchServicesTests -DWQ_LS_TESTING WQLaunchServices.m tests/WQLaunchServicesTests.m

printf '\n== Python release and static UI checks ==\n'
python3 -m unittest discover -s tests -p 'test_*.py' -v > "$OUT/python-tests.log" 2>&1 || {
    cat "$OUT/python-tests.log" >&2
    exit 1
}
tail -5 "$OUT/python-tests.log"
python3 tests/browser_ui_regressions.py | tee "$OUT/browser-ui.log"

if [[ "${WQ_SKIP_IOS_CHECK:-0}" != 1 ]]; then
    printf '\n== Strict iOS arm64 syntax/link checks ==\n'
    IOS_SDK=$(xcrun --sdk iphoneos --show-sdk-path)
    MIN_OS=$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' Info.plist)
    SOURCES=(WQCore.m WQAccess.m WQLaunchServices.m WQUI.m WQSharing.m WQApps.m WQCache.m WQPlistEditor.m WQHexViewer.m WQSQLiteViewer.m WQArchive.m WQOperation.m main.m)
    FLAGS=(-fobjc-arc -fmodules "-fmodules-cache-path=$OUT/modules-ios" -arch arm64 "-miphoneos-version-min=$MIN_OS" -isysroot "$IOS_SDK" -Wall -Wextra -Werror -O2)
    xcrun --sdk iphoneos clang -fsyntax-only "${FLAGS[@]}" "${SOURCES[@]}" > "$OUT/ios-syntax.log" 2>&1 || {
        cat "$OUT/ios-syntax.log" >&2
        exit 1
    }
    xcrun --sdk iphoneos clang "${FLAGS[@]}" -framework UIKit -framework Foundation -framework Security -framework UniformTypeIdentifiers -lsqlite3 -lz \
        "${SOURCES[@]}" -o "$OUT/WQFiles-link-check" > "$OUT/ios-link.log" 2>&1 || {
        cat "$OUT/ios-link.log" >&2
        exit 1
    }
    printf 'iOS syntax and link checks: PASS\n'
else
    printf '\niOS syntax/link checks explicitly skipped (WQ_SKIP_IOS_CHECK=1).\n'
fi
plutil -lint Info.plist entitlements.plist | tee "$OUT/plist-lint.log"
bash -n build.sh tests/run_all_tests.sh tests/run_tests.sh tests/run_apps_tests.sh \
    tests/run_access_safety_tests.sh tests/run_hex_helpers_tests.sh tests/run_plist_tests.sh tests/run_launchservices_tests.sh
printf '\nAll requested regression suites passed. Logs retained in: %s\n' "$OUT"
