#!/usr/bin/env python3
"""Cloud macOS smoke check; process survival requires separate screenshot review.

Apple's simctl JSON/identifier, install, launch, and screenshot guidance:
https://developer.apple.com/videos/play/wwdc2019/418/
Flutter's simulator setup and physical-device testing distinction:
https://docs.flutter.dev/platform-integration/ios/setup
"""

import json
import os
from pathlib import Path
import platform
import plistlib
import re
import subprocess
import sys
import time
import uuid


OUTPUT = Path("artifacts/simulator").resolve()
APP = Path("build/ios/iphonesimulator/Runner.app").resolve()
FATAL = re.compile(
    r"Unhandled Exception|runZonedGuarded error:|DB init failed:|FlutterError:|"
    r"PlatformDispatcher error:|Failed to start Mangayomi|"
    r"EXCEPTION CAUGHT BY .* LIBRARY|Could not (?:prepare|create root) isolate|"
    r"Error while initializing Dart VM|Library not loaded:",
    re.IGNORECASE,
)


def run(arguments, *, timeout=60, record=None):
    """Every subprocess has a deadline and records only task-specific output."""
    try:
        result = subprocess.run(
            arguments, capture_output=True, text=True, timeout=timeout, check=False
        )
    except subprocess.TimeoutExpired as error:
        if record:
            parts = (error.stdout or b"", error.stderr or b"")
            (OUTPUT / record).write_text("".join(
                part.decode(errors="replace") if isinstance(part, bytes) else part
                for part in parts
            ) + f"\nCommand timed out after {timeout} seconds.\n")
        raise
    if record:
        (OUTPUT / record).write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(
            f"{arguments[0]} {' '.join(arguments[1:3])} failed "
            f"({result.returncode}): {(result.stderr or result.stdout)[-3000:]}"
        )
    return result.stdout.strip()


def simctl(*arguments, **options):
    return run(["xcrun", "simctl", *arguments], **options)


def alive(pid):
    # Simulator processes share the host kernel (Apple WWDC19, linked above).
    os.kill(pid, 0)
    state = run(["ps", "-p", str(pid), "-o", "stat=", "-o", "comm="], timeout=10)
    if not state or state.lstrip().startswith("Z"):
        raise RuntimeError("The launched app process exited or became a zombie.")
    return state


def fatal_output():
    for filename in ("app-stdout.log", "app-stderr.log"):
        path = OUTPUT / filename
        if path.exists():
            # Logs are from this fresh, credential-free simulator only.
            match = FATAL.search(path.read_text(errors="replace"))
            if match:
                raise RuntimeError(f"Fatal startup signature in {filename}: {match[0]}")


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    summary = {
        "status": "failed",
        "device_type": "iPhone 13",
        "survival_seconds": 20,
        "ui_verified": False,
        "limitations": [
            "Process survival and screenshots are a startup smoke check, not UI assertions.",
            "Review startup.png: early caught Dart failures may not reach console logs.",
            "No physical-device, translator interaction, provider, or signing validation.",
        ],
        "diagnostic_warnings": [],
    }
    udid = None
    pid = None
    booted = False
    failure = None
    executable = "Runner"

    def best_effort(label, action):
        try:
            action()
        except Exception as error:
            summary["diagnostic_warnings"].append(f"{label}: {error}")

    try:
        if platform.system() != "Darwin" or platform.machine() != "arm64":
            raise RuntimeError("This smoke check requires an Apple Silicon macOS runner.")
        with (APP / "Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        bundle_id = info["CFBundleIdentifier"]
        executable = info["CFBundleExecutable"]
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", bundle_id):
            raise RuntimeError("The built app has an invalid bundle identifier.")
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", executable):
            raise RuntimeError("The built app has an unexpected executable name.")
        summary["bundle_id"] = bundle_id
        sdk_version = run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"])
        summary["simulator_sdk_version"] = sdk_version
        inventory = json.loads(simctl("list", "--json", record="inventory.json"))
        device_type = next(
            (item for item in inventory["devicetypes"] if item["name"] == "iPhone 13"),
            None,
        )
        if device_type is None:
            raise RuntimeError("The installed Xcode has no exact iPhone 13 device type.")
        # Stay within the installed SDK major: Xcode 16.4 can use 18.5/18.6,
        # while newer runtimes from other installed Xcodes must not be selected.
        runtimes = [
            item for item in inventory["runtimes"]
            if item.get("isAvailable")
            and item["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")
            and item["version"].split(".")[0] == sdk_version.split(".")[0]
            and "arm64" in item.get("supportedArchitectures", ["arm64"])
        ]
        if not runtimes:
            raise RuntimeError("No installed available iOS runtime matches the simulator SDK major.")
        runtime = max(runtimes, key=lambda item: tuple(map(int, item["version"].split("."))))
        summary["runtime"] = {key: runtime[key] for key in ("identifier", "name", "version")}
        # Create our own device; never erase, substitute, or clean up another device.
        created = simctl(
            "create", "Mangayomi translator smoke iPhone 13",
            device_type["identifier"], runtime["identifier"], record="create.log",
        )
        udid = str(uuid.UUID(created))
        summary["device_udid"] = udid
        simctl("boot", udid, timeout=90, record="boot.log")
        booted = True
        simctl("bootstatus", udid, "-b", timeout=240, record="bootstatus.log")
        simctl("install", udid, str(APP), timeout=120, record="install.log")
        simctl("get_app_container", udid, bundle_id, "app", record="installed-app.log")
        simctl("help", "launch", record="simctl-launch-help.log")
        launch = simctl(
            "launch", f"--stdout={OUTPUT / 'app-stdout.log'}",
            f"--stderr={OUTPUT / 'app-stderr.log'}", udid, bundle_id,
            timeout=90, record="launch.log",
        )
        match = re.search(rf"^{re.escape(bundle_id)}:\s+(\d+)\s*$", launch, re.MULTILINE)
        if not match or int(match[1]) <= 0:
            raise RuntimeError("simctl launch did not return the app process ID.")
        pid = int(match[1])
        summary["pid"] = pid
        deadline = time.monotonic() + summary["survival_seconds"]
        while True:
            state = alive(pid)
            fatal_output()
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            time.sleep(min(2, remaining))
        (OUTPUT / "app-process.log").write_text(f"PID {pid}: {state}\n")
        simctl("io", udid, "screenshot", str(OUTPUT / "startup.png"), record="screenshot.log")
        if not (OUTPUT / "startup.png").is_file():
            raise RuntimeError("Simulator did not produce the startup screenshot.")
        alive(pid)
        fatal_output()
        summary["status"] = "passed"
    except Exception as error:
        failure = str(error)
        summary["error"] = failure
    finally:
        if udid:
            best_effort("Final device state", lambda: simctl("list", "devices", "--json", record="final-devices.json"))
            if booted:
                if failure:
                    best_effort("Failure screenshot", lambda: simctl("io", udid, "screenshot", str(OUTPUT / "failure.png")))
                predicate = f"processID == {pid}" if pid else f'process == "{executable}"'
                best_effort("Unified logs", lambda: simctl("spawn", udid, "log", "show", "--style", "compact", "--last", "3m", "--debug", "--predicate", predicate, timeout=45, record="unified.log"))
            best_effort("Shutdown", lambda: simctl("shutdown", udid, timeout=60, record="shutdown.log"))
            best_effort("Delete", lambda: simctl("delete", udid, timeout=60, record="delete.log"))
        (OUTPUT / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        print(json.dumps(summary, indent=2), flush=True)
    return 1 if failure else 0


if __name__ == "__main__":
    sys.exit(main())
