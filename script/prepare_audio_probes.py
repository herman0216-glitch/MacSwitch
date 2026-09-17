#!/usr/bin/env python3
"""Build two local tone apps. Does not launch them or change system settings."""
import pathlib
import plistlib
import subprocess

root = pathlib.Path(__file__).resolve().parent.parent
destination = root / "build" / "probes"
destination.mkdir(parents=True, exist_ok=True)
binary = destination / "ToneProbe"
subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-strict-concurrency=complete", "-parse-as-library",
                str(root / "script" / "ToneProbe.swift"), "-o", str(binary)], check=True)
for label in ("A", "B"):
    bundle = destination / f"MacSwitch Tone {label}.app"
    executable = bundle / "Contents" / "MacOS" / f"Tone{label}"
    executable.parent.mkdir(parents=True, exist_ok=True)
    executable.write_bytes(binary.read_bytes())
    executable.chmod(0o755)
    with (bundle / "Contents" / "Info.plist").open("wb") as output:
        plistlib.dump({"CFBundleIdentifier": f"local.herman.MacSwitch.Tone{label}",
                      "CFBundleName": f"MacSwitch Tone {label}", "CFBundleExecutable": f"Tone{label}",
                      "CFBundlePackageType": "APPL", "LSUIElement": True,
                      "LSMinimumSystemVersion": "26.0", "NSPrincipalClass": "NSApplication"}, output)
    subprocess.run(["codesign", "--force", "--sign", "-", str(bundle)], check=True)
    print(bundle)
