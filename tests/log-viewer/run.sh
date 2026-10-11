#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
TASK_TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TASK_TEST_DIR"' EXIT
swiftc LogStore.swift tests/log-viewer/main.swift -o "$TASK_TEST_DIR/check"
"$TASK_TEST_DIR/check"
