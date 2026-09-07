#!/usr/bin/env python3
"""Manual, single-app iOS distribution on an ephemeral GitHub macOS runner.

No provisioning updates or device registration. Only the opted-in upload command
requests App Store Connect validation/upload; Apple's certificate tools may make
their own trust checks. Private tool output is withheld because Xcode/security
can include profile contents and device IDs.
"""

import argparse
import base64
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shlex
import shutil
import subprocess
import sys


SECRET_NAMES = {
    "IOS_DISTRIBUTION_P12_BASE64", "IOS_DISTRIBUTION_P12_PASSWORD",
    "IOS_ADHOC_PROFILE_BASE64", "IOS_APP_STORE_PROFILE_BASE64",
    "ASC_API_KEY_P8_BASE64", "ASC_API_KEY_ID",
    "ASC_API_ISSUER_ID",
}
INPUT_KEYS = {
    "route": "IOS_ROUTE", "source_sha": "IOS_SOURCE_SHA",
    "bundle_id": "IOS_BUNDLE_ID", "team_id": "IOS_TEAM_ID",
    "build_name": "IOS_BUILD_NAME", "build_number": "IOS_BUILD_NUMBER",
    "upload_testflight": "IOS_UPLOAD_TESTFLIGHT",
}
UUID_PATTERN = r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}"
UDID_PATTERN = r"(?:[0-9A-Fa-f]{40}|[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16})"
ARTIFACTS = Path("artifacts/signed-distribution")


class DistributionError(Exception):
    """A safe, authored error message with no credential values."""


def require(condition, message):
    if not condition:
        raise DistributionError(message)


def validate_inputs(values, workflow_sha, checkout_sha):
    require(values["route"] in {"adhoc", "testflight"}, "Unknown route.")
    require(re.fullmatch(r"[0-9a-fA-F]{40}", values["source_sha"]), "Use a full commit SHA.")
    require(values["source_sha"].lower() == workflow_sha.lower() == checkout_sha.lower(),
            "Source SHA must equal the selected workflow revision and checkout.")
    require(re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", values["bundle_id"])
            and len(values["bundle_id"]) <= 255, "Use an explicit bundle identifier.")
    require(re.fullmatch(r"[A-Z0-9]{10}", values["team_id"]), "Invalid Team ID.")
    require(re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)",
                         values["build_name"]) and len(values["build_name"]) <= 64,
            "Marketing version must have three numeric components.")
    require(re.fullmatch(r"[1-9][0-9]{0,3}(?:\.(?:0|[1-9][0-9]?)){0,2}",
                         values["build_number"]), "Invalid Apple build version (maximum 4.2.2 digits).")
    require(values["upload_testflight"] in {"true", "false"}, "Invalid upload choice.")
    require(values["upload_testflight"] != "true" or values["route"] == "testflight",
            "Apple upload is available only for the TestFlight route.")
    return values


def run(command, label, **kwargs):
    # Do not pass encoded credentials to Flutter, CocoaPods or build scripts.
    env = {key: value for key, value in os.environ.items() if key not in SECRET_NAMES}
    result = subprocess.run(command, env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, **kwargs)
    require(result.returncode == 0, f"{label} failed; private tool output was withheld.")
    return result.stdout


def inputs():
    values = {key: os.environ.get(env_key, "") for key, env_key in INPUT_KEYS.items()}
    return validate_inputs(values, os.environ.get("GITHUB_SHA", ""),
                           run(["git", "rev-parse", "HEAD"], "Read source").decode().strip())


def private_dir():
    require(os.environ.get("RUNNER_TEMP"), "Use an ephemeral GitHub macOS runner.")
    return Path(os.environ["RUNNER_TEMP"]) / "mangayomi-ios-signing"


def write_private(path, content):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.write_bytes(content)
    path.chmod(0o600)


def secret_bytes(name):
    value = os.environ.get(name, "")
    require(bool(value), f"Missing secret: {name}.")
    try:
        return base64.b64decode("".join(value.split()), validate=True)
    except (ValueError, base64.binascii.Error):
        raise DistributionError(f"Invalid base64 secret: {name}.") from None


def validate_profile(profile, values, now=None):
    now = now or dt.datetime.now(dt.timezone.utc)
    require(profile.get("TeamIdentifier") == [values["team_id"]], "Profile Team ID mismatch.")
    require("iOS" in profile.get("Platform", []), "Profile must support iOS.")
    expiry = profile.get("ExpirationDate")
    creation = profile.get("CreationDate")
    require(isinstance(creation, dt.datetime) and creation.replace(tzinfo=dt.timezone.utc) <= now,
            "Profile creation date is missing or in the future.")
    require(isinstance(expiry, dt.datetime), "Profile expiry is missing.")
    require(expiry.replace(tzinfo=dt.timezone.utc) > now, "Provisioning profile expired.")
    entitlements = profile.get("Entitlements", {})
    prefixes = profile.get("ApplicationIdentifierPrefix", [])
    require(len(prefixes) == 1 and re.fullmatch(r"[A-Z0-9]{10}", prefixes[0]),
            "Profile App ID prefix is invalid.")
    app_id = f"{prefixes[0]}.{values['bundle_id']}"
    require(entitlements.get("application-identifier") == app_id,
            "Profile must match the explicit bundle identifier (no wildcard profiles).")
    require(entitlements.get("com.apple.developer.team-identifier") == values["team_id"],
            "Profile entitlement Team ID mismatch.")
    require(entitlements.get("get-task-allow") is False, "A distribution profile is required.")
    require(not profile.get("ProvisionsAllDevices"), "Enterprise profiles are unsupported.")
    require(re.fullmatch(UUID_PATTERN, profile.get("UUID", "")), "Invalid profile UUID.")
    require(bool(profile.get("DeveloperCertificates")), "Profile has no signing certificate.")
    devices = profile.get("ProvisionedDevices", [])
    if values["route"] == "adhoc":
        require(bool(devices) and all(re.fullmatch(UDID_PATTERN, item) for item in devices),
                "Ad hoc profile must contain registered devices.")
    else:
        require(not devices and entitlements.get("beta-reports-active") is True,
                "Use an App Store Connect distribution profile for TestFlight.")
    return app_id


def export_options(values, profile_uuid, identity):
    return {
        "method": "release-testing" if values["route"] == "adhoc" else "app-store-connect",
        "destination": "export", "signingStyle": "manual",
        "teamID": values["team_id"], "signingCertificate": identity,
        "provisioningProfiles": {values["bundle_id"]: profile_uuid},
        "manageAppVersionAndBuildNumber": False, "stripSwiftSymbols": True,
        "thinning": "<none>",
    }


def preflight():
    values = inputs()
    require(os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch", "Manual dispatch is required.")
    version = run(["xcodebuild", "-version"], "Read Xcode version").decode().strip()
    sdk = run(["xcrun", "--sdk", "iphoneos", "--show-sdk-version"], "Read iOS SDK").decode().strip()
    require(version == "Xcode 26.6\nBuild version 17F113" and sdk == "26.5",
            "Expected Xcode 26.6 (17F113) with iOS 26.5 SDK; review runner inventory.")
    require(run(["uname", "-m"], "Read architecture").strip() == b"arm64", "An arm64 runner is required.")
    run(["ruby", "-e", "require 'xcodeproj'"], "Check Runner project editor dependency")
    help_result = subprocess.run(["xcodebuild", "-help"], capture_output=True)
    help_text = help_result.stdout + help_result.stderr
    require(all(method in help_text for method in (b"release-testing", b"app-store-connect")),
            "Installed Xcode does not document the selected export methods.")
    run(["ruby", "-e", "require 'xcodeproj'"], "Check installed CocoaPods project library")
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    (ARTIFACTS / "source.json").write_text(json.dumps({
        **values, "xcode": version, "ios_sdk": sdk,
        "notice": "Signing and Apple processing do not validate physical-device behavior.",
    }, indent=2) + "\n")
    print("Inputs, source revision and supported Apple SDK validated.")


def configure_runner(values, profile_uuid, identity):
    # CocoaPods already supplies xcodeproj. Change only the Runner Release
    # target; never override bundle IDs/profiles globally across Pods/tests.
    ruby = """
require 'xcodeproj'
project = Xcodeproj::Project.open('ios/Runner.xcodeproj')
apps = project.targets.select { |target| target.product_type == 'com.apple.product-type.application' }
raise 'Expected one Runner application' unless apps.length == 1 && apps.first.name == 'Runner'
raise 'App extensions require explicit signing support' if project.targets.any? { |t| t.product_type == 'com.apple.product-type.app-extension' }
config = apps.first.build_configurations.find { |item| item.name == 'Release' }
raise 'Missing Runner Release configuration' unless config
settings = config.build_settings
settings['PRODUCT_BUNDLE_IDENTIFIER'] = ARGV[0]
settings['DEVELOPMENT_TEAM'] = ARGV[1]
settings['CODE_SIGN_STYLE'] = 'Manual'
settings['CODE_SIGN_IDENTITY'] = ARGV[3]
settings['CODE_SIGN_IDENTITY[sdk=iphoneos*]'] = ARGV[3]
settings['PROVISIONING_PROFILE_SPECIFIER'] = ARGV[2]
settings['PROVISIONING_PROFILE'] = ARGV[2]
project.save
"""
    run(["ruby", "-e", ruby, values["bundle_id"], values["team_id"], profile_uuid, identity],
        "Configure Runner signing")


def build():
    values = inputs()
    working = private_dir()
    require(not working.exists(), "Signing directory already exists; clean up the previous attempt.")
    working.mkdir(mode=0o700)
    # Protect private files individually; Flutter/Xcode must retain normal
    # bundle permissions rather than inherit a restrictive process-wide umask.
    try:
        profile_path = working / "distribution.mobileprovision"
        profile_secret = "IOS_ADHOC_PROFILE_BASE64" if values["route"] == "adhoc" else "IOS_APP_STORE_PROFILE_BASE64"
        write_private(profile_path, secret_bytes(profile_secret))
        profile = plistlib.loads(run(["security", "cms", "-D", "-i", str(profile_path)], "Decode profile"))
        app_id = validate_profile(profile, values)
        p12 = working / "distribution.p12"
        write_private(p12, secret_bytes("IOS_DISTRIBUTION_P12_BASE64"))
        password = os.environ.get("IOS_DISTRIBUTION_P12_PASSWORD", "")
        require(bool(password), "Missing secret: IOS_DISTRIBUTION_P12_PASSWORD.")
        keychain = working / "distribution.keychain-db"
        installed_profile = Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles" / f"{profile['UUID']}.mobileprovision"
        require(not installed_profile.exists(), "Provisioning profile path already exists.")
        original_keychains = shlex.split(run(["security", "list-keychains", "-d", "user"], "Read keychain list").decode())
        write_private(working / "cleanup.json", json.dumps({
            "keychain": str(keychain), "profile": str(installed_profile),
            "original_keychains": original_keychains,
        }).encode())
        keychain_password = secrets.token_urlsafe(32)
        run(["security", "create-keychain", "-p", keychain_password, str(keychain)], "Create temporary keychain")
        run(["security", "set-keychain-settings", "-lut", "3600", str(keychain)], "Set temporary keychain expiry")
        run(["security", "unlock-keychain", "-p", keychain_password, str(keychain)], "Unlock temporary keychain")
        run(["security", "import", str(p12), "-P", password, "-t", "cert", "-f", "pkcs12", "-k", str(keychain),
             "-T", "/usr/bin/codesign", "-T", "/usr/bin/security"], "Import distribution identity")
        p12.unlink()
        run(["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-k", keychain_password,
             str(keychain)], "Allow Apple signing tools")
        run(["security", "list-keychains", "-d", "user", "-s", str(keychain), *original_keychains], "Select signing keychain")
        identities = run(["security", "find-identity", "-v", "-p", "codesigning", str(keychain)], "Validate distribution identity").decode()
        profile_hashes = {hashlib.sha1(cert).hexdigest().upper() for cert in profile["DeveloperCertificates"]}
        matching = [fingerprint for fingerprint, label in re.findall(r'\d+\) ([0-9A-F]{40}) "([^"\n]+)"', identities)
                    if fingerprint in profile_hashes and label.startswith(("Apple Distribution:", "iPhone Distribution:"))]
        require(len(matching) == 1, "P12 must contain one valid distribution identity included in the profile.")
        identity = matching[0]
        write_private(installed_profile, profile_path.read_bytes())
        configure_runner(values, profile["UUID"], identity)
        options = working / "ExportOptions.plist"
        write_private(options, plistlib.dumps(export_options(values, profile["UUID"], identity)))
        print("Profile and distribution identity validated. Archiving Release app...", flush=True)
        run(["flutter", "build", "ipa", "--release", "--no-pub", f"--build-name={values['build_name']}",
             f"--build-number={values['build_number']}", f"--export-options-plist={options}"], "Xcode archive/export")
        candidates = list(Path("build/ios/ipa").glob("*.ipa"))
        require(len(candidates) == 1, "Xcode must export exactly one IPA.")
        verify_ipa(candidates[0], values, app_id, identity, working)
        destination = ARTIFACTS / f"Mangayomi-{values['route']}.ipa"
        shutil.copyfile(candidates[0], destination)
        (ARTIFACTS / "result.json").write_text(json.dumps({
            "route": values["route"], "source_sha": values["source_sha"],
            "ipa_sha256": hashlib.sha256(destination.read_bytes()).hexdigest(),
            "signature_verified": True,
            "apple_upload_status": "Not attempted at export time; inspect the separate upload step.",
            "physical_device_tested": False,
        }, indent=2) + "\n")
        print("Signed IPA and embedded provisioning verified; GitHub artifact is ready.")
    finally:
        cleanup()


def verify_ipa(ipa, values, app_id, identity, working):
    unpacked = working / "verified-ipa"
    run(["ditto", "-x", "-k", str(ipa), str(unpacked)], "Open exported IPA")
    applications = list((unpacked / "Payload").glob("*.app"))
    require(len(applications) == 1, "IPA must contain exactly one application.")
    app = applications[0]
    require(not list(app.glob("PlugIns/*.appex")), "App extensions require explicit signing support.")
    run(["codesign", "--verify", "--deep", "--strict", str(app)], "Verify complete code signature")
    info = plistlib.loads((app / "Info.plist").read_bytes())
    for key, expected in (("CFBundleIdentifier", values["bundle_id"]),
                          ("CFBundleShortVersionString", values["build_name"]),
                          ("CFBundleVersion", values["build_number"])):
        require(info.get(key) == expected, f"Exported {key} does not match the requested value.")
    require(info.get("DTSDKName") == "iphoneos26.5", "Exported app used an unexpected SDK.")
    embedded = plistlib.loads(run(["security", "cms", "-D", "-i", str(app / "embedded.mobileprovision")], "Read embedded profile"))
    require(validate_profile(embedded, values) == app_id, "Exported profile App ID changed.")
    entitlements = plistlib.loads(run(["codesign", "-d", "--entitlements", ":-", str(app)], "Read signed entitlements"))
    require(entitlements.get("get-task-allow", False) is False, "Exported app allows debugger attachment.")
    require(entitlements.get("application-identifier") == app_id and
            entitlements.get("com.apple.developer.team-identifier") == values["team_id"],
            "Signed app identifiers do not match the provisioning profile.")
    certificate_prefix = working / "signed-certificate"
    run(["codesign", "-d", "--extract-certificates", str(certificate_prefix), str(app)], "Read signing certificate")
    require(hashlib.sha1(Path(f"{certificate_prefix}0").read_bytes()).hexdigest().upper() == identity,
            "Exported app uses an unexpected distribution certificate.")


def upload():
    values = inputs()
    require(values["route"] == "testflight" and values["upload_testflight"] == "true",
            "Explicit TestFlight upload opt-in is required.")
    key_id = os.environ.get("ASC_API_KEY_ID", "")
    issuer = os.environ.get("ASC_API_ISSUER_ID", "")
    require(re.fullmatch(r"[A-Z0-9]{10}", key_id), "Set a valid ASC_API_KEY_ID.")
    require(re.fullmatch(UUID_PATTERN, issuer), "Set a valid ASC_API_ISSUER_ID.")
    ipa = (ARTIFACTS / "Mangayomi-testflight.ipa").resolve()
    result = json.loads((ARTIFACTS / "result.json").read_text())
    require(result.get("signature_verified") is True and result.get("source_sha") == values["source_sha"]
            and result.get("ipa_sha256") == hashlib.sha256(ipa.read_bytes()).hexdigest(),
            "The verified IPA has changed; refusing upload.")
    working = private_dir()
    working.mkdir(mode=0o700)
    try:
        # altool documents this directory relative to its working directory.
        write_private(working / "private_keys" / f"AuthKey_{key_id}.p8", secret_bytes("ASC_API_KEY_P8_BASE64"))
        common = ["-f", str(ipa), "-t", "ios", "--apiKey", key_id, "--apiIssuer", issuer]
        run(["xcrun", "altool", "--validate-app", *common], "Apple build validation", cwd=working)
        run(["xcrun", "altool", "--upload-app", *common], "App Store Connect upload", cwd=working)
        print("App Store Connect accepted the upload command. Processing and tester availability remain pending.")
    finally:
        cleanup()


def cleanup():
    working = private_dir()
    state = working / "cleanup.json"
    failed = False
    if state.exists():
        values = json.loads(state.read_text())
        # Cleanup output is also private. Never remove unrelated profiles.
        restored = subprocess.run(["security", "list-keychains", "-d", "user", "-s", *values["original_keychains"]], capture_output=True)
        failed = restored.returncode != 0
        if Path(values["keychain"]).exists():
            deleted = subprocess.run(["security", "delete-keychain", values["keychain"]], capture_output=True)
            failed = failed or deleted.returncode != 0
        try:
            Path(values["profile"]).unlink(missing_ok=True)
        except OSError:
            failed = True
    if working.exists():
        try:
            shutil.rmtree(working)
        except OSError:
            failed = True
    for path in (Path("build/ios/archive"), Path("build/ios/ipa")):
        if path.exists():
            try:
                shutil.rmtree(path)
            except OSError:
                failed = True
    require(not failed, "Some signing cleanup failed; discard the ephemeral runner.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("preflight", "build", "upload", "cleanup"))
    args = parser.parse_args()
    try:
        globals()[args.command]()
    except DistributionError as error:
        print(f"::error::{error}", file=sys.stderr)
        sys.exit(1)
    except (ValueError, OSError, KeyError, TypeError, plistlib.InvalidFileException):
        # Do not print exception objects that can contain credential/profile data.
        # Parser/library exceptions can carry data, so use generic failure text.
        print("::error::iOS distribution failed. Check route inputs, signing-secret presence, profile validity, and the selected Apple toolchain.", file=sys.stderr)
        sys.exit(1)
