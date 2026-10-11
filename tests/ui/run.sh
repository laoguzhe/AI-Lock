#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
UI_TEST_DIR="$(mktemp -d /tmp/ailock-ui.XXXXXX)"
trap 'rm -rf "$UI_TEST_DIR"' EXIT
SOURCES=()
while IFS= read -r source; do SOURCES+=("$source"); done < <(python3 - <<'PY'
import re
for path in re.search(r'SOURCES=\((.*?)\)',open('build.sh').read(),re.S).group(1).split():
    if path != 'AppDelegate.swift': print(path)
PY
)
swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.0" "${SOURCES[@]}" tests/ui/main.swift -o "$UI_TEST_DIR/ui-check"
"$UI_TEST_DIR/ui-check" "${1:-/tmp/ailock-files-ui.png}" "${2:-files}"
