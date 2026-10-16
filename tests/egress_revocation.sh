#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output="$PWD/test-results/egress-revocation-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$output"
stream_source="${EGRESS_STREAM_SOURCE:-Sources/HoneyObs/EgressStream.swift}"
swiftc -swift-version 5 -D EGRESS_STREAM_TESTING -framework Foundation -framework Network -framework Security -framework Virtualization \
  Sources/HoneyObs/{Relay,EgressPolicy}.swift "$stream_source" tests/EgressRevocationChecks.swift -o "$output/checks"
"$output/checks" "$@"
