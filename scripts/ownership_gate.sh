#!/bin/bash
# 実外部経路を使わない専用variant。一度作った.appを後続試験で上書きしない。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p test-results
clang -O2 -Wall -Wextra -Werror tests/pressure_worker.c -o test-results/pressure-worker
variant_root="$(mktemp -d "$PWD/test-results/ownership-build.XXXXXX")"
variant_app="$variant_root/Applications.noindex/HoneyObs.app"
mkdir -p "$variant_root/Applications.noindex"
codesign --verify --deep --strict build/Applications.noindex/HoneyObs.app
/usr/bin/ditto build/Applications.noindex/HoneyObs.app "$variant_app"
swiftc -swift-version 5 -D EGRESS_TESTING -framework Cocoa -framework Virtualization -framework Network -framework WebKit \
  Sources/HoneyObs/*.swift -o "$variant_app/Contents/MacOS/HoneyObs"
codesign --force --sign - --entitlements entitlements.plist "$variant_app"
HONEYOBS_APP="$variant_app" python3 tests/session_ownership.py --egress-fixture "$@"
