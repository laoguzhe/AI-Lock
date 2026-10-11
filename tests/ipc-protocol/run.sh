#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
IPC_CHECK_DIR="$(mktemp -d /tmp/ailock-ipc-check.XXXXXX)"
trap 'rm -rf "$IPC_CHECK_DIR"' EXIT
swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.0" extensions/AuditIPC.swift extensions/AuditEventBuffer.swift extensions/FilterHealthIPC.swift tests/ipc-protocol/main.swift -o "$IPC_CHECK_DIR/check"
"$IPC_CHECK_DIR/check"
