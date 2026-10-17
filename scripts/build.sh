#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="$(python3 scripts/build_paths.py)"
python3 scripts/prepare.py
python3 scripts/prepare_egress.py
python3 scripts/prepare_gui.py
mkdir -p "$app/Contents/MacOS"
mkdir -p "$app/Contents/Helpers"
swiftc -swift-version 5 -O -framework Cocoa -framework Virtualization -framework Network -framework WebKit \
  Sources/HoneyObs/*.swift -o "$app/Contents/MacOS/HoneyObs"
cp Info.plist "$app/Contents/Info.plist"
swiftc -parse-as-library -swift-version 5 -O Sources/HoneyObs/SessionOwnership.swift \
  Sources/SessionMonitor/Main.swift -o "$app/Contents/Helpers/HoneyObsSession"
codesign --force --sign - "$app/Contents/Helpers/HoneyObsSession"
codesign --force --sign - --entitlements entitlements.plist "$app"
codesign --verify --deep --strict "$app"
