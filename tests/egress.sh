#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p test-results/egress-bin
swiftc -swift-version 5 -D EGRESS_TESTING -framework Foundation -framework Virtualization -framework Network -framework Security \
  Sources/HoneyObs/{EgressPolicy,EgressStream,EgressVM,Relay}.swift tests/EgressChecks.swift \
  -o test-results/egress-bin/checks
codesign --force --sign - --entitlements entitlements.plist test-results/egress-bin/checks
test-results/egress-bin/checks "$PWD" "$@"
