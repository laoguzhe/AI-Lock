#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
TEST_DIR="$(mktemp -d /tmp/ailock-menubar-tests.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.0" MenuBarOrganizer.swift Localization.swift tests/menu-bar/main.swift -o "$TEST_DIR/check"
"$TEST_DIR/check" "${1:-/tmp/ailock-menubar-settings.png}"
