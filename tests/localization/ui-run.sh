#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
TEST_DIR="$(mktemp -d /tmp/ailock-language-ui.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
SOURCES=()
while IFS= read -r source; do SOURCES+=("$source"); done < <(python3 - <<'PY'
import re
for path in re.search(r'SOURCES=\((.*?)\)',open('build.sh').read(),re.S).group(1).split():
    if path != 'AppDelegate.swift': print(path)
PY
)
cp tests/localization/ui-main.swift "$TEST_DIR/main.swift"
swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.0" "${SOURCES[@]}" "$TEST_DIR/main.swift" -o "$TEST_DIR/ui"
"$TEST_DIR/ui"
