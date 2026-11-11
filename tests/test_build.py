#!/usr/bin/env python3
import os
import stat
import shutil
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build.sh"


FAKE_XCRUN = r'''#!/bin/sh
set -eu
if [ "$1" = "--sdk" ] && [ "$3" = "--show-sdk-path" ]; then
    printf '%s\n' "$FAKE_SDK"
    exit 0
fi
if [ "$1" = "--sdk" ] && [ "$3" = "clang" ]; then
    output=
    previous=
    for argument in "$@"; do
        if [ "$previous" = "-o" ]; then output=$argument; fi
        previous=$argument
    done
    test -n "$output"
    printf '#!/bin/sh\nexit 0\n' > "$output"
    chmod +x "$output"
    exit 0
fi
exit 2
'''

FAKE_CODESIGN = r'''#!/bin/sh
set -eu
last=
for argument in "$@"; do last=$argument; done
if [ "$1" = "-f" ]; then
    entitlements=
    previous=
    for argument in "$@"; do
        if [ "$previous" = "--entitlements" ]; then entitlements=$argument; fi
        previous=$argument
    done
    mkdir -p "$last/_CodeSignature"
    printf 'fixture signature\n' > "$last/_CodeSignature/CodeResources"
    if [ "${FAKE_DROP_GROUP:-0}" = 1 ]; then
        printf '<plist version="1.0"><dict/></plist>\n' > "$last/.fake-entitlements.plist"
    else
        cp "$entitlements" "$last/.fake-entitlements.plist"
    fi
    exit 0
fi
if [ "$1" = "--verify" ]; then
    test -x "$last/WQFiles"
    test -f "$last/_CodeSignature/CodeResources"
    exit 0
fi
if [ "$1" = "-d" ]; then
    /usr/bin/plutil -convert xml1 -o - "$last/.fake-entitlements.plist"
    exit 0
fi
exit 2
'''

FAKE_ZIP = r'''#!/bin/sh
set -eu
if [ "${FAKE_ZIP_FAIL:-0}" = 1 ]; then
    echo 'injected zip failure' >&2
    exit 9
fi
exec /usr/bin/zip "$@"
'''

FAKE_UNZIP = r'''#!/bin/sh
set -eu
exec /usr/bin/unzip "$@"
'''


class StagedBuildTests(unittest.TestCase):
    def _fake_environment(self, directory: Path):
        fake_bin = directory / "bin"
        fake_bin.mkdir()
        fake_sdk = directory / "sdk"
        fake_sdk.mkdir()
        for name, content in {
            "xcrun": FAKE_XCRUN,
            "codesign": FAKE_CODESIGN,
            "zip": FAKE_ZIP,
            "unzip": FAKE_UNZIP,
        }.items():
            path = fake_bin / name
            path.write_text(content, encoding="utf-8")
            path.chmod(path.stat().st_mode | stat.S_IXUSR)
        environment = os.environ.copy()
        environment["PATH"] = f"{fake_bin}:{environment['PATH']}"
        environment["FAKE_SDK"] = str(fake_sdk)
        environment["WQ_SKIP_PREFLIGHT"] = "1"
        return environment

    def test_default_output_stays_in_project(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            project = root / "project"
            project.mkdir()
            for name in ("build.sh", "Info.plist", "entitlements.plist"):
                shutil.copy2(ROOT / name, project / name)
            (project / "icons").mkdir()
            (project / "icons" / "AppIcon60x60@2x.png").write_bytes(b"fixture icon")
            environment = self._fake_environment(root)
            environment.pop("WQFILES_FINAL_IPA", None)
            result = subprocess.run(
                [str(project / "build.sh")], cwd=project, env=environment,
                text=True, capture_output=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((project / "WQFiles.ipa").is_file())
            self.assertFalse((root / "WQFiles.ipa").exists())

    def test_success_publishes_only_a_validated_zip(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            final = root / "release" / "WQFiles.ipa"
            final.parent.mkdir()
            final.write_bytes(b"previous release")
            environment = self._fake_environment(root)
            environment["WQFILES_FINAL_IPA"] = str(final)
            result = subprocess.run(
                [str(BUILD)], cwd=ROOT, env=environment,
                text=True, capture_output=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotEqual(final.read_bytes(), b"previous release")
            with zipfile.ZipFile(final) as archive:
                self.assertIsNone(archive.testzip())
                self.assertIn("Payload/WQFiles.app/WQFiles", archive.namelist())
                self.assertIn("Payload/WQFiles.app/Info.plist", archive.namelist())

    def test_zip_failure_preserves_existing_final_ipa_and_cleans_siblings(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            final = root / "release" / "WQFiles.ipa"
            final.parent.mkdir()
            original = b"previous release bytes"
            final.write_bytes(original)
            environment = self._fake_environment(root)
            environment["WQFILES_FINAL_IPA"] = str(final)
            environment["FAKE_ZIP_FAIL"] = "1"
            result = subprocess.run(
                [str(BUILD)], cwd=ROOT, env=environment,
                text=True, capture_output=True, check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(final.read_bytes(), original)
            self.assertEqual(list(final.parent.glob(".WQFiles.ipa.*")), [])
            self.assertEqual(list(final.parent.glob(".WQFiles-build.*")), [])

    def test_missing_signed_app_group_preserves_existing_final_ipa(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            final = root / "release" / "WQFiles.ipa"
            final.parent.mkdir()
            original = b"previous release bytes"
            final.write_bytes(original)
            environment = self._fake_environment(root)
            environment["WQFILES_FINAL_IPA"] = str(final)
            environment["FAKE_DROP_GROUP"] = "1"
            result = subprocess.run(
                [str(BUILD)], cwd=ROOT, env=environment,
                text=True, capture_output=True, check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(final.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
