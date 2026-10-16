#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p test-results/lifecycle-bin
swiftc -swift-version 5 -framework Cocoa -framework Virtualization -framework Network \
  Sources/HoneyObs/{Engine,Relay,ObservedEvent,ObservationStore,GeoIP,EgressVM,EgressStream,EgressPolicy,BoundedConsole}.swift tests/LifecycleChecks.swift \
  -o test-results/lifecycle-bin/checks
codesign --force --sign - --entitlements entitlements.plist test-results/lifecycle-bin/checks
test-results/lifecycle-bin/checks "$PWD"
