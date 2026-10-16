#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p test-results/console-capture
swiftc -swift-version 5 Sources/HoneyObs/{BoundedConsole,EgressPolicy}.swift tests/BoundedConsoleCaptureChecks.swift -o test-results/console-capture/checks
test-results/console-capture/checks "$PWD/test-results/console-capture"
