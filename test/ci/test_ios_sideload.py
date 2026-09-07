"""Pure Python artifact checks; these tests never run Flutter or Apple tools."""

import importlib.util
import os
from pathlib import Path
import plistlib
import stat
import struct
import tempfile
import unittest
from unittest.mock import patch
import zipfile


SCRIPT = Path(__file__).resolve().parents[2] / ".github/scripts/package_ios_sideload.py"
SPEC = importlib.util.spec_from_file_location("package_ios_sideload", SCRIPT)
PACKAGER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGER)


def device_binary(*, platform=2, cpu=0x0100000C, filetype=2):
    # Minimal arm64 Mach-O header and LC_BUILD_VERSION for metadata testing.
    command = struct.pack("<6I", 0x32, 24, platform, 15 << 16, 26 << 16, 0)
    return struct.pack("<8I", 0xFEEDFACF, cpu, 0, filetype, 1, len(command), 0, 0) + command


class SideloadArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.app = self.root / "Runner.app"
        self.app.mkdir()
        metadata = {
            "CFBundlePackageType": "APPL", "CFBundleIdentifier": "com.example.translator",
            "CFBundleExecutable": "Runner", "CFBundleSupportedPlatforms": ["iPhoneOS"],
            "DTPlatformName": "iphoneos", "MinimumOSVersion": "15.0", "UIDeviceFamily": [1, 2],
            "CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "7",
        }
        (self.app / "Info.plist").write_bytes(plistlib.dumps(metadata))
        for relative, filetype in (
            ("Runner", 2), ("Frameworks/App.framework/App", 6),
            ("Frameworks/Flutter.framework/Flutter", 6),
        ):
            binary = self.app / relative
            binary.parent.mkdir(parents=True, exist_ok=True)
            binary.write_bytes(device_binary(filetype=filetype))
            binary.chmod(0o755)
        (self.app / "Frameworks/App.framework/flutter_assets").mkdir()
        (self.app / "Current").symlink_to("Runner")
        self.archive = self.root / "candidate.ipa"

    def write_archive(self, *, mutate=None, missing=None, extra=None):
        with zipfile.ZipFile(self.archive, "w") as archive:
            for path in (self.app, *self.app.rglob("*")):
                name = str(Path("Payload/Runner.app") / path.relative_to(self.app))
                if name == missing:
                    continue
                mode = path.lstat().st_mode
                entry = zipfile.ZipInfo(name + ("/" if stat.S_ISDIR(mode) else ""))
                entry.create_system = 3
                entry.external_attr = mode << 16
                if path.is_symlink():
                    data = os.readlink(path).encode("utf-8")
                else:
                    data = path.read_bytes() if path.is_file() else b""
                if mutate:
                    data = mutate(entry, data)
                archive.writestr(entry, data)
            if extra:
                archive.writestr(extra, b"unexpected")

    def test_arm64_simulator_is_rejected_despite_matching_cpu(self):
        binary = self.app / "Runner"
        self.assertEqual(PACKAGER.mach_o_device(binary, 2)["architectures"], ["arm64"])
        binary.write_bytes(device_binary(platform=7))
        with self.assertRaisesRegex(ValueError, "simulator"):
            PACKAGER.mach_o_device(binary, 2)

    def test_wrong_cpu_and_truncated_mach_o_are_rejected(self):
        binary = self.app / "Runner"
        for data in (device_binary(cpu=0x01000007), device_binary()[:-1]):
            with self.subTest(data_length=len(data)):
                binary.write_bytes(data)
                with self.assertRaises(ValueError):
                    PACKAGER.mach_o_device(binary, 2)
        # Universal binaries must validate their inner slice, not only the fat header.
        fat_header = struct.pack(">2I", 0xCAFEBABE, 1) + struct.pack(">5I", 0x0100000C, 0, 28, 56, 0)
        binary.write_bytes(fat_header + device_binary())
        self.assertEqual(PACKAGER.mach_o_device(binary, 2)["minimum_ios"], [15, 0, 0])
        binary.write_bytes(fat_header + device_binary(platform=7))
        with self.assertRaisesRegex(ValueError, "simulator"):
            PACKAGER.mach_o_device(binary, 2)

    def test_app_requires_aot_snapshot_exports(self):
        exported = "\n".join(f"0000000000001000 T {name}" for name in PACKAGER.AOT_SYMBOLS)
        with patch.object(PACKAGER, "run", return_value=exported) as command:
            metadata = PACKAGER.inspect_bundle(self.app)
            self.assertEqual(metadata["bundle_id"], "com.example.translator")
            self.assertEqual(command.call_args.args[0][:3], ["/usr/bin/xcrun", "nm", "-gU"])
        with patch.object(PACKAGER, "run", return_value="0000000000001000 T _main"):
            with self.assertRaisesRegex(ValueError, "AOT snapshot"):
                PACKAGER.inspect_bundle(self.app)

    def test_frameworks_keep_0644_mode_while_main_requires_execute_permission(self):
        frameworks = ("Frameworks/App.framework/App", "Frameworks/Flutter.framework/Flutter")
        for relative in frameworks:
            (self.app / relative).chmod(0o644)
        exported = "\n".join(f"0000000000001000 T {name}" for name in PACKAGER.AOT_SYMBOLS)
        with patch.object(PACKAGER, "run", return_value=exported):
            self.assertEqual(PACKAGER.inspect_bundle(self.app)["executable"], "Runner")
        inventory = PACKAGER.bundle_inventory(self.app)
        self.write_archive()
        self.assertEqual(PACKAGER.verify_archive(self.archive, inventory), len(inventory))
        with zipfile.ZipFile(self.archive) as archive:
            for relative in frameworks:
                mode = archive.getinfo(f"Payload/Runner.app/{relative}").external_attr >> 16
                self.assertEqual(stat.S_IMODE(mode), 0o644)
        (self.app / "Runner").chmod(0o644)
        with self.assertRaisesRegex(ValueError, "main app executable lacks execute permissions"):
            PACKAGER.inspect_bundle(self.app)

    def test_bundle_rejects_escaping_links_profiles_and_jit_assets(self):
        (self.root / "outside").write_bytes(b"outside the app")
        escape = self.app / "Escape"
        escape.symlink_to("../outside")
        with self.assertRaisesRegex(ValueError, "symlink"):
            PACKAGER.bundle_inventory(self.app)
        escape.unlink()
        for name, message in (("embedded.mobileprovision", "Provisioning"),
                              ("kernel_blob.bin", "JIT snapshot")):
            with self.subTest(name=name):
                path = self.app / name
                path.write_bytes(b"not production data")
                with self.assertRaisesRegex(ValueError, message):
                    PACKAGER.bundle_inventory(self.app)
                path.unlink()

    def test_archive_preserves_files_permissions_and_relative_links(self):
        inventory = PACKAGER.bundle_inventory(self.app)
        self.write_archive()
        self.assertEqual(PACKAGER.verify_archive(self.archive, inventory), len(inventory))

    def test_archive_rejects_modified_or_missing_executable(self):
        inventory = PACKAGER.bundle_inventory(self.app)
        main = "Payload/Runner.app/Runner"

        def replace_executable(entry, data):
            return b"replaced executable" if entry.filename == main else data

        self.write_archive(mutate=replace_executable)
        with self.assertRaisesRegex(ValueError, "contents differ"):
            PACKAGER.verify_archive(self.archive, inventory)
        self.write_archive(missing=main)
        with self.assertRaisesRegex(ValueError, "missing required"):
            PACKAGER.verify_archive(self.archive, inventory)

    def test_archive_rejects_path_traversal_permission_loss_and_link_change(self):
        inventory = PACKAGER.bundle_inventory(self.app)
        self.write_archive(extra="Payload/Runner.app/../../escape")
        with self.assertRaisesRegex(ValueError, "unsafe archive path"):
            PACKAGER.verify_archive(self.archive, inventory)

        def remove_execute_permission(entry, data):
            if entry.filename == "Payload/Runner.app/Runner":
                entry.external_attr &= ~(0o111 << 16)
            return data

        self.write_archive(mutate=remove_execute_permission)
        with self.assertRaisesRegex(ValueError, "permissions"):
            PACKAGER.verify_archive(self.archive, inventory)

        def escape_link(entry, data):
            return b"../../outside" if entry.filename == "Payload/Runner.app/Current" else data

        self.write_archive(mutate=escape_link)
        with self.assertRaisesRegex(ValueError, "symlink"):
            PACKAGER.verify_archive(self.archive, inventory)


if __name__ == "__main__":
    unittest.main()
