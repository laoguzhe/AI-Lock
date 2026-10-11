#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
CHECK_DIR="$(mktemp -d /tmp/ailock-index-check.XXXXXX)"
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.0" FileModels.swift FileScanService.swift DirectoryIndex.swift DirectoryActivityMonitor.swift FileActivityService.swift tests/index-integration/main.swift -o "$CHECK_DIR/check"
"$CHECK_DIR/check"
