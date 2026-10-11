#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
SNAPSHOT_TEST_DIR="$(mktemp -d /tmp/ailock-network-snapshot.XXXXXX)"
trap 'rm -rf "$SNAPSHOT_TEST_DIR"' EXIT
swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.0" AppSupport.swift NetworkInspector.swift tests/network-snapshot/main.swift -o "$SNAPSHOT_TEST_DIR/check"
"$SNAPSHOT_TEST_DIR/check"
