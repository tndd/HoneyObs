#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/prepare.py
python3 scripts/prepare_gui.py
mkdir -p build/HoneyObs.app/Contents/MacOS
swiftc -swift-version 5 -O -framework Cocoa -framework Virtualization -framework Network -framework WebKit \
  Sources/HoneyObs/*.swift -o build/HoneyObs.app/Contents/MacOS/HoneyObs
cp Info.plist build/HoneyObs.app/Contents/Info.plist
codesign --force --sign - build/HoneyObs.app/Contents/Resources/cloudflared
codesign --force --sign - --entitlements entitlements.plist build/HoneyObs.app
codesign --verify --deep --strict build/HoneyObs.app
