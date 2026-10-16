#!/bin/bash
# VM・同梱カーネル・ネットワーク・インストール済みアプリを使わない検証。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p test-results/unit-bin
swiftc -swift-version 5 Sources/HoneyObs/{GeoIP,ObservedEvent,ObservationStore}.swift \
  tests/ObservationChecks.swift -o test-results/unit-bin/observations
test-results/unit-bin/observations
swiftc -swift-version 5 Sources/HoneyObs/{GeoIP,ObservedEvent,ObservationStore,ObservationDrain}.swift \
  tests/ObservationDrainChecks.swift -o test-results/unit-bin/observation-drain
test-results/unit-bin/observation-drain
# 許可の製品実装を直接リンクする。Virtualization.frameworkへリンクするがVMは生成しない。
swiftc -swift-version 5 -framework Network -framework Virtualization \
  Sources/HoneyObs/Relay.swift tests/PermitChecks.swift -o test-results/unit-bin/permit
test-results/unit-bin/permit
swiftc -swift-version 5 Sources/HoneyObs/{LaunchOptions,SessionArchive}.swift tests/LaunchOptionsChecks.swift \
  -o test-results/unit-bin/launch-options
test-results/unit-bin/launch-options
swiftc -swift-version 5 Sources/HoneyObs/SessionArchive.swift tests/SessionArchiveChecks.swift \
  -o test-results/unit-bin/session-archive
test-results/unit-bin/session-archive
swiftc -swift-version 5 Sources/HoneyObs/SessionArchive.swift tests/SessionArchiveLockChecks.swift \
  -o test-results/unit-bin/session-archive-lock
test-results/unit-bin/session-archive-lock
swiftc -swift-version 5 Sources/HoneyObs/BoundedConsole.swift tests/BoundedConsoleChecks.swift \
  -o test-results/unit-bin/bounded-console
test-results/unit-bin/bounded-console
python3 tests/install_checks.py
