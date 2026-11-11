#!/usr/bin/env python3
import plistlib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class ReleasePolicyTests(unittest.TestCase):
    def test_info_plist_declares_documented_ios_26_minimum(self):
        with (ROOT / "Info.plist").open("rb") as plist_file:
            info = plistlib.load(plist_file)
        self.assertEqual(info["MinimumOSVersion"], "26.0")

    def test_ipad_declares_all_orientations(self):
        with (ROOT / "Info.plist").open("rb") as plist_file:
            info = plistlib.load(plist_file)
        self.assertEqual(set(info["UISupportedInterfaceOrientations~ipad"]), {
            "UIInterfaceOrientationPortrait",
            "UIInterfaceOrientationPortraitUpsideDown",
            "UIInterfaceOrientationLandscapeLeft",
            "UIInterfaceOrientationLandscapeRight",
        })

    def test_signing_requests_app_group_but_not_signer_owned_identifier(self):
        with (ROOT / "entitlements.plist").open("rb") as plist_file:
            entitlements = plistlib.load(plist_file)
        self.assertNotIn("application-identifier", entitlements)
        self.assertEqual(
            entitlements["com.apple.security.application-groups"],
            ["group.cz.kolbi.wqfiles"],
        )

    def test_build_and_catalog_policy_are_explicitly_26_0(self):
        build_script = (ROOT / "build.sh").read_text(encoding="utf-8")
        updater = (ROOT / "scripts" / "update_source.py").read_text(encoding="utf-8")
        self.assertIn("MINIMUM_IOS_VERSION=26.0", build_script)
        self.assertIn('MINIMUM_IOS_VERSION = "26.0"', updater)


if __name__ == "__main__":
    unittest.main()
