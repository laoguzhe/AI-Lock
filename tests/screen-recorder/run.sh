#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
test_dir="$(mktemp -d /tmp/ailock-recording-tests.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
swiftc -parse-as-library -swift-version 5 ScreenRecorder.swift tests/screen-recorder/RecordingTests.swift -o "$test_dir/recording-tests"
"$test_dir/recording-tests"
