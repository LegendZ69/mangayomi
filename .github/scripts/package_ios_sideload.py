#!/usr/bin/env python3
"""Package a cloud-built, unsigned release app for AltStore/SideStore re-signing.

Run on the GitHub macOS runner AFTER:
  flutter build ios --release --no-codesign --no-pub
This script neither builds nor signs the app. The IPA cannot be installed until
the recipient's sideloading tool signs it with an appropriate Apple profile.

Release/signing guidance: https://docs.flutter.dev/deployment/ios
Mach-O constants: https://github.com/apple-oss-distributions/xnu/blob/main/EXTERNAL_HEADERS/mach-o/loader.h
"""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import plistlib
import re
import stat
import struct
import subprocess
import sys
import tempfile
import zipfile


DEFAULT_APP = "build/ios/iphoneos/Runner.app"
DEFAULT_OUTPUT = "artifacts/distribution/Mangayomi-translator-sideload-unsigned.ipa"
JIT_FILES = {"kernel_blob.bin", "vm_snapshot_data", "isolate_snapshot_data"}
PRIVATE_SUFFIXES = {".mobileprovision", ".p12", ".pfx", ".p8"}
AOT_SYMBOLS = {
    "_kDartVmSnapshotData", "_kDartVmSnapshotInstructions",
    "_kDartIsolateSnapshotData", "_kDartIsolateSnapshotInstructions",
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(arguments, timeout=120):
    result = subprocess.run(
        arguments, check=False, capture_output=True, text=True, timeout=timeout
    )
    # Never echo command output, environment values, profiles or private keys.
    require(result.returncode == 0, f"{Path(arguments[0]).name} failed ({result.returncode}).")
    return result.stdout.strip()


def digest(stream):
    checksum = hashlib.sha256()
    for block in iter(lambda: stream.read(1024 * 1024), b""):
        checksum.update(block)
    return checksum.hexdigest()


def version_tuple(value):
    require(isinstance(value, str) and re.fullmatch(r"\d+(?:\.\d+){0,2}", value),
            "Expected a resolved numeric version in the built Info.plist.")
    parts = tuple(map(int, value.split(".")))
    return parts + (0,) * (3 - len(parts))


def mach_o_device(path, expected_filetype):
    """Read every thin/fat Mach-O slice; arm64 alone is also used by simulators."""
    with path.open("rb") as stream:
        magic = stream.read(4)
        total_size = path.stat().st_size
        if magic in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
            wide = magic[-1] == 0xBF
            count = struct.unpack(">I", stream.read(4))[0]
            require(0 < count <= 32, "Invalid universal Mach-O slice count.")
            slices = []
            for _ in range(count):
                record = struct.unpack(">IIQQII" if wide else ">IIIII",
                                       stream.read(32 if wide else 20))
                slices.append((record[2], record[3]))
            require(all(offset >= 8 + count * (32 if wide else 20)
                        for offset, _ in slices), "Invalid universal Mach-O offsets.")
        else:
            slices = [(0, total_size)]
        minimum_versions = []
        for offset, size in slices:
            require(size >= 32 and offset + size <= total_size,
                    "Truncated Mach-O slice.")
            stream.seek(offset)
            header = struct.unpack("<8I", stream.read(32))
            require(header[0] == 0xFEEDFACF and header[1] == 0x0100000C,
                    "Every executable slice must be a 64-bit arm64 Mach-O.")
            require(header[3] == expected_filetype, "Unexpected Mach-O file type.")
            command_count, command_bytes = header[4:6]
            require(command_count > 0 and command_bytes <= size - 32,
                    "Invalid Mach-O load commands.")
            commands = stream.read(command_bytes)
            position = 0
            versions = []
            for _ in range(command_count):
                require(position + 8 <= len(commands), "Truncated Mach-O load command.")
                command, length = struct.unpack_from("<II", commands, position)
                require(length >= 8 and length % 4 == 0 and position + length <= len(commands),
                        "Invalid Mach-O load command length.")
                if command == 0x32:  # LC_BUILD_VERSION; PLATFORM_IOS is 2.
                    require(length >= 24, "Truncated Mach-O build version.")
                    target, minimum = struct.unpack_from("<II", commands, position + 8)
                    require(target == 2, "Mach-O targets a simulator or a non-iOS platform.")
                    versions.append(minimum)
                elif command == 0x25:  # Legacy LC_VERSION_MIN_IPHONEOS.
                    require(length >= 16, "Truncated Mach-O minimum version.")
                    versions.append(struct.unpack_from("<I", commands, position + 8)[0])
                elif command in (0x24, 0x2F, 0x30):
                    raise ValueError("Mach-O targets macOS, tvOS or watchOS.")
                position += length
            require(position == command_bytes and versions,
                    "Mach-O must declare its physical iOS deployment target.")
            minimum_versions.extend(
                (value >> 16, (value >> 8) & 255, value & 255) for value in versions
            )
    return {"architectures": ["arm64"], "minimum_ios": list(max(minimum_versions))}


def inspect_bundle(app):
    require(app.is_dir() and not app.is_symlink() and app.suffix == ".app",
            "Input must be a real .app directory.")
    with (app / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    require(info.get("CFBundlePackageType") == "APPL", "Input is not an application bundle.")
    bundle_id = info.get("CFBundleIdentifier")
    require(isinstance(bundle_id, str) and re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle_id),
            "The built bundle identifier is invalid or unresolved.")
    executable = info.get("CFBundleExecutable")
    require(isinstance(executable, str) and re.fullmatch(r"[A-Za-z0-9_.-]+", executable)
            and executable not in (".", ".."), "Invalid executable name.")
    require(info.get("CFBundleSupportedPlatforms") == ["iPhoneOS"]
            and info.get("DTPlatformName") == "iphoneos",
            "Input must be built for physical iOS devices, not a simulator.")
    minimum = version_tuple(info.get("MinimumOSVersion"))
    require(minimum >= (13, 0, 0), "Unexpected iOS deployment target for this Flutter app.")
    version_tuple(info.get("CFBundleShortVersionString"))
    version_tuple(info.get("CFBundleVersion"))
    family = info.get("UIDeviceFamily")
    require(isinstance(family, list) and 1 in family
            and all(type(item) is int and item in (1, 2) for item in family),
            "The built app must support the iPhone device family.")
    binaries = {
        executable: 2,  # MH_EXECUTE
        "Frameworks/App.framework/App": 6,  # MH_DYLIB; compiled Dart AOT code.
        "Frameworks/Flutter.framework/Flutter": 6,
    }
    details = {}
    for relative, filetype in binaries.items():
        binary = app / relative
        require(binary.is_file() and binary.stat().st_mode & 0o111,
                "A required app or Flutter framework executable is missing.")
        details[relative] = mach_o_device(binary, filetype)
        require(tuple(details[relative]["minimum_ios"]) <= minimum,
                "Info.plist minimum iOS is lower than an executable's deployment target.")
    require((app / "Frameworks/App.framework/flutter_assets").is_dir(),
            "The app is missing its Flutter assets.")
    symbols = run(["/usr/bin/xcrun", "nm", "-gU", str(app / "Frameworks/App.framework/App")])
    exported = {line.split()[-1] for line in symbols.splitlines() if line.split()}
    require(AOT_SYMBOLS <= exported,
            "App.framework does not export all four Dart AOT snapshot symbols.")
    return {
        "bundle_id": bundle_id, "version": info["CFBundleShortVersionString"],
        "build": info["CFBundleVersion"], "minimum_ios": info["MinimumOSVersion"],
        "device_family": family, "executable": executable,
        "executable_architectures": details, "dart_aot_symbols_verified": sorted(AOT_SYMBOLS),
    }


def bundle_inventory(app):
    """Capture contents/modes; reject escaping links and unexpected private files."""
    inventory = {}
    for path in (app, *app.rglob("*")):
        relative = PurePosixPath("Payload/Runner.app") / path.relative_to(app).as_posix()
        name = str(relative)
        require(path.name not in JIT_FILES, "JIT snapshot assets are not allowed in this release IPA.")
        require(path.suffix.lower() not in PRIVATE_SUFFIXES,
                "Provisioning profiles or private signing material must not enter the unsigned IPA.")
        mode = path.lstat().st_mode
        require(stat.S_IFMT(mode) in (stat.S_IFDIR, stat.S_IFREG, stat.S_IFLNK),
                "The app bundle contains an unsupported filesystem entry.")
        require(not mode & (stat.S_ISUID | stat.S_ISGID), "Unexpected privileged file mode.")
        entry = {"mode": mode}
        if path.is_symlink():
            target = os.readlink(path)
            require(not os.path.isabs(target) and "\\" not in target
                    and path.resolve(strict=True).is_relative_to(app),
                    "An app bundle symlink escapes the bundle or is invalid.")
            entry["target"] = target
        elif path.is_file():
            with path.open("rb") as stream:
                entry["sha256"] = digest(stream)
        inventory[name] = entry
    return inventory


def verify_archive(archive, inventory):
    """Verify in place, without extracting; compare every file and symlink."""
    with zipfile.ZipFile(archive) as package:
        seen = set()
        for item in package.infolist():
            name = item.filename.rstrip("/")
            parts = name.split("/")
            require(name and not name.startswith("/") and "\\" not in name
                    and all(part not in ("", ".", "..") for part in parts),
                    "IPA contains an unsafe archive path.")
            require(name not in seen and not item.flag_bits & 1,
                    "IPA contains duplicate paths or encrypted entries.")
            seen.add(name)
            if name == "Payload":
                require(item.is_dir(), "Payload must be a directory.")
                continue
            require(name in inventory, "IPA contains an unexpected entry outside the app inventory.")
            expected = inventory[name]
            mode = item.external_attr >> 16
            require(stat.S_IFMT(mode) == stat.S_IFMT(expected["mode"])
                    and stat.S_IMODE(mode) == stat.S_IMODE(expected["mode"]),
                    "IPA failed to preserve bundle file types or permissions.")
            if "target" in expected:
                require(package.read(item).decode("utf-8") == expected["target"],
                        "IPA failed to preserve a validated bundle symlink.")
            elif "sha256" in expected:
                with package.open(item) as stream:
                    require(digest(stream) == expected["sha256"], "IPA contents differ from the built app.")
        require(set(inventory) <= seen, "IPA is missing required bundle files.")
    return len(inventory)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=Path(DEFAULT_APP))
    parser.add_argument("--output", type=Path, default=Path(DEFAULT_OUTPUT))
    parser.add_argument("--source-commit", help="Expected checked-out commit; verified against git HEAD.")
    arguments = parser.parse_args()
    require(platform.system() == "Darwin" and os.environ.get("GITHUB_ACTIONS") == "true",
            "Run packaging only in the authorized GitHub-hosted macOS workflow.")
    require(not arguments.app.is_symlink(), "Input app must not be a symlink.")
    app = arguments.app.resolve(strict=True)
    output = arguments.output.resolve()
    manifest_path = output.with_suffix(".manifest.json")
    require(output.suffix == ".ipa" and not output.is_relative_to(app), "Invalid IPA destination.")
    require(not output.exists() and not manifest_path.exists(), "Refusing to replace existing distribution artifacts.")
    commit = run(["git", "rev-parse", "HEAD"])
    require(re.fullmatch(r"[0-9a-f]{40}", commit), "Unable to identify the checked-out source revision.")
    if arguments.source_commit is not None:
        require(arguments.source_commit == commit, "Requested source revision does not match git HEAD.")
    inventory = bundle_inventory(app)
    metadata = inspect_bundle(app)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="ios-sideload-", dir=output.parent) as temporary:
        staging = Path(temporary)
        payload = staging / "Payload"
        payload.mkdir()
        run(["/usr/bin/ditto", "--norsrc", "--noextattr", "--noacl", str(app), str(payload / "Runner.app")])
        candidate = staging / "candidate.ipa"
        run(["/usr/bin/ditto", "-c", "-k", "--norsrc", "--noextattr", "--noacl",
             "--keepParent", str(payload), str(candidate)], timeout=300)
        entries = verify_archive(candidate, inventory)
        with candidate.open("rb") as stream:
            sha256 = digest(stream)
        manifest = {
            "schema_version": 1, "source_commit": commit, "mode": "unsigned-release",
            "build_mode_source": "Workflow invokes flutter build ios --release --no-codesign --no-pub.",
            **metadata, "file": output.name, "sha256": sha256,
            "size_bytes": candidate.stat().st_size, "verified_bundle_entries": entries,
            "requires_resigning": True, "installable_as_downloaded": False,
            "provisioning_profile_included": False,
            "provider_configuration": "Enter provider credentials in the installed app; packaging injects none.",
            "limitations": [
                "AOT and device-platform checks do not validate physical-device installation or execution.",
                "AltStore/SideStore must re-sign this IPA; it is not an Ad Hoc or TestFlight export.",
                "Private signing-file checks are not an exhaustive scan for credentials compiled into binaries.",
            ],
        }
        candidate_manifest = staging / "manifest.json"
        candidate_manifest.write_text(json.dumps(manifest, indent=2) + "\n")
        candidate.replace(output)
        candidate_manifest.replace(manifest_path)
    print(json.dumps(manifest, indent=2), flush=True)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, struct.error, zipfile.BadZipFile,
            subprocess.TimeoutExpired) as error:
        print(f"Sideload packaging failed: {error}", file=sys.stderr)
        sys.exit(1)
