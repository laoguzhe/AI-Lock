#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
BENCHMARK_DIR="$(mktemp -d /tmp/ailock-benchmark-binary.XXXXXX)"
trap 'rm -rf "$BENCHMARK_DIR"' EXIT
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" AppSettings.swift ClipboardHistory.swift ClipboardRepository.swift tests/benchmark/main.swift -o "$BENCHMARK_DIR/benchmark"
"$BENCHMARK_DIR/benchmark"
