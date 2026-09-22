#!/usr/bin/env python3
"""Build the native local Mac app without third-party UI dependencies."""
import plistlib
import subprocess
import platform
import shutil
from pathlib import Path

root = Path(__file__).resolve().parents[1]
app = root / "dist/Agent Display.app"
contents = app / "Contents"
(contents / "MacOS").mkdir(parents=True, exist_ok=True)
(contents / "Resources").mkdir(parents=True, exist_ok=True)
launcher = contents / "Resources/OpenCode.command"
shutil.copy2(root / "desktop/OpenCode.command", launcher)
launcher.chmod(0o755)
with (contents / "Info.plist").open("wb") as stream:
    plistlib.dump({"CFBundleIdentifier": "com.codex.tip.desktop", "CFBundleName": "Agent Display",
                  "CFBundleExecutable": "AgentDisplay", "CFBundlePackageType": "APPL",
                  "CFBundleShortVersionString": "2.0.0", "CFBundleVersion": "2",
                  "NSBluetoothAlwaysUsageDescription": "通过蓝牙向 M5Stack 推送任务状态，并接收长按隐藏操作。",
                  "LSMinimumSystemVersion": "13.0", "NSHighResolutionCapable": True,
                  "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True}}, stream)
subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-O", "-swift-version", "5",
                "-target", f"{platform.machine()}-apple-macosx13.0",
                *map(str, sorted((root / "desktop").glob("*.swift"))), "-o", str(contents / "MacOS/AgentDisplay"),
                "-framework", "SwiftUI", "-framework", "AppKit", "-framework", "CoreBluetooth",
                "-framework", "Network", "-framework", "UserNotifications", "-lsqlite3"], check=True)
subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
print(app)
