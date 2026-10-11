#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
AUDIT_TEST_DIR="$(mktemp -d /tmp/ailock-audit-tests.XXXXXX)"
trap 'rm -rf "$AUDIT_TEST_DIR"' EXIT
swiftc -swift-version 5 FileModels.swift AuditExtensionClient.swift extensions/AuditIPC.swift tests/file-audit/main.swift -o "$AUDIT_TEST_DIR/check"
"$AUDIT_TEST_DIR/check"
