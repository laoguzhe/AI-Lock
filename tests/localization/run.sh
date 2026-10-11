#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
TEST_DIR="$(mktemp -d /tmp/ailock-localization.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
python3 tests/localization/audit.py
swiftc Localization.swift AppSettings.swift tests/localization/main.swift -o "$TEST_DIR/localization"
"$TEST_DIR/localization"
