#!/usr/bin/env python3
"""Build the native local Mac app without third-party UI dependencies."""
import plistlib
import subprocess
import platform
from pathlib import Path

root = Path(__file__).resolve().parents[1]
app = root / "dist/Agent Display.app"
contents = app / "Contents"
(contents / "MacOS").mkdir(parents=True, exist_ok=True)
with (contents / "Info.plist").open("wb") as stream:
    plistlib.dump({"CFBundleIdentifier": "com.codex.tip.desktop", "CFBundleName": "Agent Display",
                  "CFBundleExecutable": "AgentDisplay", "CFBundlePackageType": "APPL",
                  "CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "1",
                  "LSMinimumSystemVersion": "13.0", "NSHighResolutionCapable": True,
                  "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True}}, stream)
subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-O", "-swift-version", "5",
                "-target", f"{platform.machine()}-apple-macosx13.0",
                str(root / "desktop/AgentDisplay.swift"), "-o", str(contents / "MacOS/AgentDisplay"),
                "-framework", "SwiftUI", "-framework", "AppKit"], check=True)
subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
print(app)
