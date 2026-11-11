#!/usr/bin/env python3
import importlib.util
import json
import os
import plistlib
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts" / "update_source.py"
SPEC = importlib.util.spec_from_file_location("wq_update_source", MODULE_PATH)
UPDATE_SOURCE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(UPDATE_SOURCE)

BUNDLE_ID = "cz.kolbi.wqfiles"


def write_source(path: Path, minimum_os: str = "16.0") -> None:
    source = {
        "name": "test source",
        "apps": [
            {
                "bundleIdentifier": BUNDLE_ID,
                "versions": [
                    {
                        "version": "0.4",
                        "buildVersion": "4",
                        "minOSVersion": minimum_os,
                    }
                ],
            }
        ],
    }
    path.write_text(json.dumps(source, indent=2) + "\n", encoding="utf-8")


def write_ipa(path: Path, *, info=None, malformed=False, missing_app=False) -> None:
    if malformed:
        path.write_bytes(b"not a zip")
        return
    if info is None:
        info = {
            "CFBundleIdentifier": BUNDLE_ID,
            "CFBundleShortVersionString": "0.5",
            "CFBundleVersion": "5",
            "CFBundleExecutable": "WQFiles",
            "MinimumOSVersion": "27.0",
        }
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        if not missing_app:
            archive.writestr(
                "Payload/WQFiles.app/Info.plist",
                plistlib.dumps(info, fmt=plistlib.FMT_BINARY),
            )
            archive.writestr("Payload/WQFiles.app/WQFiles", b"signed fixture executable")


class UpdateSourceTests(unittest.TestCase):
    def test_matching_ipa_succeeds_and_uses_embedded_minimum_os(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.json"
            ipa = root / "WQFiles.ipa"
            write_source(source, minimum_os="16.0")
            write_ipa(ipa)

            entry = UPDATE_SOURCE.update_catalog(source, "0.5", "5", ipa, "fixture")
            result = json.loads(source.read_text(encoding="utf-8"))
            self.assertEqual(entry["version"], "0.5")
            self.assertEqual(entry["buildVersion"], "5")
            self.assertEqual(entry["minOSVersion"], "27.0")
            self.assertEqual(entry["size"], ipa.stat().st_size)
            self.assertEqual(result["apps"][0]["versions"][0], entry)
            self.assertEqual(len(result["apps"][0]["versions"]), 2)

    def test_rejects_identity_version_build_and_policy_mismatches_without_mutation(self):
        cases = (
            ("identity", {"CFBundleIdentifier": "wrong.example"}),
            ("version", {"CFBundleShortVersionString": "9.9"}),
            ("build", {"CFBundleVersion": "99"}),
            ("minimum OS", {"MinimumOSVersion": "17.0"}),
        )
        for label, change in cases:
            with self.subTest(label=label), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                source = root / "source.json"
                ipa = root / "WQFiles.ipa"
                write_source(source)
                write_ipa(ipa, info={
                    "CFBundleIdentifier": BUNDLE_ID,
                    "CFBundleShortVersionString": "0.5",
                    "CFBundleVersion": "5",
                    "CFBundleExecutable": "WQFiles",
                    "MinimumOSVersion": "27.0",
                    **change,
                })
                original = source.read_bytes()
                with self.assertRaises(ValueError):
                    UPDATE_SOURCE.update_catalog(source, "0.5", "5", ipa)
                self.assertEqual(source.read_bytes(), original)

    def test_rejects_missing_and_malformed_ipas_without_mutation(self):
        for fixture in ("missing", "malformed"):
            with self.subTest(fixture=fixture), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                source = root / "source.json"
                ipa = root / "WQFiles.ipa"
                write_source(source)
                if fixture == "missing":
                    write_ipa(ipa, missing_app=True)
                else:
                    write_ipa(ipa, malformed=True)
                original = source.read_bytes()
                with self.assertRaises(ValueError):
                    UPDATE_SOURCE.update_catalog(source, "0.5", "5", ipa)
                self.assertEqual(source.read_bytes(), original)

    def test_existing_description_is_preserved_when_notes_are_omitted(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.json"
            ipa = root / "WQFiles.ipa"
            write_source(source)
            catalog = json.loads(source.read_text(encoding="utf-8"))
            catalog["apps"][0]["versions"][0]["version"] = "0.5"
            catalog["apps"][0]["versions"][0]["buildVersion"] = "5"
            catalog["apps"][0]["versions"][0]["localizedDescription"] = "keep this text"
            source.write_text(json.dumps(catalog, indent=2) + "\n", encoding="utf-8")
            write_ipa(ipa)
            entry = UPDATE_SOURCE.update_catalog(source, "0.5", "5", ipa, "")
            self.assertEqual(entry["localizedDescription"], "keep this text")

    def test_malformed_xml_info_plist_is_a_clean_value_error(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ipa = root / "WQFiles.ipa"
            with zipfile.ZipFile(ipa, "w") as archive:
                archive.writestr("Payload/WQFiles.app/Info.plist", b"<plist><dict>")
                archive.writestr("Payload/WQFiles.app/WQFiles", b"executable")
            with self.assertRaises(ValueError):
                UPDATE_SOURCE.read_ipa_metadata(ipa)

    def test_missing_ipa_is_rejected_before_catalog_write(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.json"
            write_source(source)
            original = source.read_bytes()
            with self.assertRaises(ValueError):
                UPDATE_SOURCE.update_catalog(source, "0.5", "5", root / "missing.ipa")
            self.assertEqual(source.read_bytes(), original)

    def test_replace_failure_preserves_catalog_and_cleans_temporary_sibling(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.json"
            ipa = root / "WQFiles.ipa"
            write_source(source)
            write_ipa(ipa)
            original = source.read_bytes()
            with mock.patch.object(UPDATE_SOURCE.os, "replace", side_effect=OSError("injected replace failure")):
                with self.assertRaises(OSError):
                    UPDATE_SOURCE.update_catalog(source, "0.5", "5", ipa)
            self.assertEqual(source.read_bytes(), original)
            self.assertEqual(list(root.glob(".source.json.*.tmp")), [])

    def test_invalid_zip_member_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ipa = root / "WQFiles.ipa"
            with zipfile.ZipFile(ipa, "w") as archive:
                archive.writestr("Payload/WQFiles.app/Info.plist", b"not plist")
                archive.writestr("Payload/WQFiles.app/WQFiles", b"executable")
            with self.assertRaises(ValueError):
                UPDATE_SOURCE.read_ipa_metadata(ipa)


if __name__ == "__main__":
    unittest.main()
