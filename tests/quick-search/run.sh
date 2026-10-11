#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
SEARCH_TEST_DIR="$(mktemp -d /tmp/ailock-search-tests.XXXXXX)"
trap 'rm -rf "$SEARCH_TEST_DIR"' EXIT
swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
    AppSupport.swift Localization.swift ApplicationCatalog.swift DirectoryActivityMonitor.swift FileModels.swift AppSettings.swift QuickSearch.swift \
    tests/quick-search/main.swift -o "$SEARCH_TEST_DIR/search-check"
"$SEARCH_TEST_DIR/search-check"
