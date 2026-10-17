#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
resources="${1:-$PWD/build/Applications.noindex/HoneyObs.app/Contents/Resources}"
output="$PWD/test-results/relay-closure-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$output/resources"
cp "$resources/vmlinuz" "$resources/initramfs.gz" "$output/resources/"
swiftc -swift-version 5 -framework Foundation -framework Virtualization -framework Network \
  Sources/HoneyObs/Relay.swift tests/RelayClosureChecks.swift -o "$output/checks"
codesign --force --sign - --entitlements entitlements.plist "$output/checks"
"$output/checks" "$output/resources"
