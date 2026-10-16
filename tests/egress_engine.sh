#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p test-results/egress-engine-bin
swiftc -swift-version 5 -D EGRESS_TESTING -framework Cocoa -framework Virtualization -framework Network -framework Security \
  Sources/HoneyObs/{Engine,Relay,ObservedEvent,ObservationStore,ObservationDrain,SessionArchive,GeoIP,EgressVM,EgressStream,EgressPolicy,EgressTestingFixture,BoundedConsole}.swift \
  tests/EgressEngineChecks.swift -o test-results/egress-engine-bin/checks
codesign --force --sign - --entitlements entitlements.plist test-results/egress-engine-bin/checks
test-results/egress-engine-bin/checks "$PWD"
