"""Pure signing guard tests. Never invoke Flutter, Xcode, security or Apple APIs."""

import copy
import datetime as dt
import importlib.util
from pathlib import Path
import unittest


SPEC = importlib.util.spec_from_file_location(
    "ios_signing", Path(__file__).resolve().parents[2] / ".github/scripts/ios_signing.py"
)
SIGNING = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SIGNING)
NOW = dt.datetime(2026, 9, 7, tzinfo=dt.timezone.utc)
SHA = "a" * 40


def values(route="adhoc"):
    return {
        "route": route, "source_sha": SHA, "bundle_id": "org.example.mangayomi",
        "team_id": "ABC123DE45", "build_name": "0.1.0", "build_number": "1.0.1",
        "upload_testflight": "false",
    }


def profile(route="adhoc"):
    data = {
        "TeamIdentifier": ["ABC123DE45"], "Platform": ["iOS"],
        "CreationDate": NOW - dt.timedelta(days=1),
        "ExpirationDate": NOW + dt.timedelta(days=1),
        "ApplicationIdentifierPrefix": ["OLD123AB45"],
        "UUID": "00000000-1111-2222-3333-444444444444",
        "DeveloperCertificates": [b"synthetic-certificate-for-pure-guard-test"],
        "Entitlements": {
            "application-identifier": "OLD123AB45.org.example.mangayomi",
            "com.apple.developer.team-identifier": "ABC123DE45",
            "get-task-allow": False,
        },
    }
    if route == "adhoc":
        data["ProvisionedDevices"] = ["00000000-0000000000000000", "a" * 40]
    else:
        data["Entitlements"]["beta-reports-active"] = True
    return data


class InputTests(unittest.TestCase):
    def test_reviewed_revision_and_valid_versions_are_accepted(self):
        for version in ("1", "9999.99.99"):
            data = values()
            data["build_number"] = version
            self.assertIs(SIGNING.validate_inputs(data, SHA, SHA), data)

    def test_revision_must_match_both_workflow_and_checkout(self):
        for workflow, checkout in (("b" * 40, SHA), (SHA, "c" * 40)):
            with self.subTest(workflow=workflow, checkout=checkout):
                with self.assertRaises(SIGNING.DistributionError):
                    SIGNING.validate_inputs(values(), workflow, checkout)

    def test_invalid_inputs_and_upload_without_testflight_are_rejected(self):
        cases = {
            "source_sha": ("main", SHA + "\n"),
            "route": ("enterprise", "../adhoc"),
            "bundle_id": ("org.example.*", "org.example\nEVIL=1", "$(touch bad)", "org/example"),
            "team_id": ("TEAM", "ABC123DE45\n"),
            "build_name": ("1.0", "1.0.0-beta", "01.0.0"),
            "build_number": ("0", "10000", "1.100", "1.1.100", "1.2.3.4", "1;bad", "01"),
            "upload_testflight": ("yes", "true"),
        }
        for key, invalid_values in cases.items():
            for invalid in invalid_values:
                with self.subTest(key=key, invalid=invalid):
                    data = values()
                    data[key] = invalid
                    with self.assertRaises(SIGNING.DistributionError):
                        SIGNING.validate_inputs(data, SHA, SHA)

    def test_testflight_upload_requires_explicit_true(self):
        data = values("testflight")
        data["upload_testflight"] = "true"
        self.assertIs(SIGNING.validate_inputs(data, SHA, SHA), data)


class ProfileTests(unittest.TestCase):
    def test_valid_profiles_accept_legacy_app_prefix_distinct_from_team(self):
        for route in ("adhoc", "testflight"):
            self.assertEqual(SIGNING.validate_profile(profile(route), values(route), now=NOW),
                             "OLD123AB45.org.example.mangayomi")

    def test_bad_profile_metadata_is_rejected(self):
        cases = {
            "TeamIdentifier": ["OTHER12345"], "Platform": ["macOS"],
            "CreationDate": NOW + dt.timedelta(seconds=1), "ExpirationDate": NOW,
            "UUID": "../unsafe", "ApplicationIdentifierPrefix": ["*"],
            "DeveloperCertificates": [], "ProvisionsAllDevices": True,
        }
        for key, invalid in cases.items():
            with self.subTest(key=key):
                data = profile()
                data[key] = invalid
                with self.assertRaises(SIGNING.DistributionError):
                    SIGNING.validate_profile(data, values(), now=NOW)

    def test_development_wildcard_or_wrong_team_entitlements_are_rejected(self):
        for key, invalid in (("get-task-allow", True), ("application-identifier", "OLD123AB45.*"),
                             ("com.apple.developer.team-identifier", "OTHER12345")):
            data = profile()
            data["Entitlements"][key] = invalid
            with self.subTest(key=key):
                with self.assertRaises(SIGNING.DistributionError):
                    SIGNING.validate_profile(data, values(), now=NOW)

    def test_adhoc_requires_real_device_ids(self):
        for devices in ([], ["not-a-device"], ["00000000-0000000000000000\n"]):
            data = profile()
            data["ProvisionedDevices"] = devices
            with self.assertRaises(SIGNING.DistributionError):
                SIGNING.validate_profile(data, values(), now=NOW)

    def test_testflight_rejects_device_profiles_and_missing_beta_entitlement(self):
        data = profile("testflight")
        for invalid in (profile("adhoc"), {**data, "ProvisionedDevices": ["a" * 40]}):
            with self.assertRaises(SIGNING.DistributionError):
                SIGNING.validate_profile(invalid, values("testflight"), now=NOW)
        invalid = copy.deepcopy(data)
        del invalid["Entitlements"]["beta-reports-active"]
        with self.assertRaises(SIGNING.DistributionError):
            SIGNING.validate_profile(invalid, values("testflight"), now=NOW)

    def test_export_is_manual_and_never_uploads_or_changes_the_build_number(self):
        for route, method in (("adhoc", "release-testing"), ("testflight", "app-store-connect")):
            result = SIGNING.export_options(values(route), "profile-uuid", "identity-sha")
            self.assertEqual(result["method"], method)
            self.assertEqual(result["destination"], "export")
            self.assertEqual(result["signingStyle"], "manual")
            self.assertFalse(result["manageAppVersionAndBuildNumber"])
            self.assertEqual(result["provisioningProfiles"], {"org.example.mangayomi": "profile-uuid"})


if __name__ == "__main__":
    unittest.main()
