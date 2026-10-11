#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
TEST_DIR="$(mktemp -d /tmp/ailock-network-tests.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
# Test production history, filtering and CSV generation without launching the UI.
cat > "$TEST_DIR/Support.swift" <<'SWIFT'
import AppKit
class ModuleViewController: NSViewController {}
struct MonitoredProcess { let pid: pid_t; let startTime: Date }
enum CommandRunner {
    static func run(_ path: String, arguments: [String], allowEmptyExit: Bool) throws -> String { "" }
}
SWIFT
cp tests/network-activity/main.swift "$TEST_DIR/main.swift"
swiftc -swift-version 5 Localization.swift NetworkModuleController.swift ProcessNetworkMonitor.swift NetworkInspector.swift NetworkObservationService.swift "$TEST_DIR/Support.swift" "$TEST_DIR/main.swift" -o "$TEST_DIR/check"
"$TEST_DIR/check"
