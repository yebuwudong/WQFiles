#!/usr/bin/env python3
import importlib.util
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

    def test_catalog_policy_is_explicitly_26_0(self):
        # Load the updater and check its active constant, not source text.
        # The build's effective deployment target is checked by running
        # build.sh with fake tools (test_build.test_compiles_for_the_info_plist_minimum_os).
        spec = importlib.util.spec_from_file_location(
            "wq_update_source_policy", ROOT / "scripts" / "update_source.py")
        module = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(module)
        self.assertEqual(module.MINIMUM_IOS_VERSION, "26.0")

if __name__ == "__main__":
    unittest.main()
