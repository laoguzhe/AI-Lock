#!/bin/bash
# Build a local DMG, or delegate to the signed and notarized release pipeline.
set -euo pipefail

cd "$(dirname "$0")"

VERSION="${VERSION:-1.2}"
BUILD_NUM="${BUILD_NUM:-3}"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ && "$BUILD_NUM" =~ ^[0-9]+$ ]] || {
	echo "Invalid VERSION or BUILD_NUM" >&2
	exit 1
}

if [[ "${1:-}" == "--release" ]]; then
	[[ $# -eq 1 ]] || { echo "Usage: $0 [--release]" >&2; exit 2; }
	export VERSION BUILD_NUM
	exec ./release.sh
fi

[[ $# -eq 0 ]] || { echo "Usage: $0 [--release]" >&2; exit 2; }

# Keep local packaging separate from build/AILock-$VERSION.dmg release assets.
BUILD_DIR="${BUILD_DIR:-build/package}"
VERSION="$VERSION" BUILD_NUM="$BUILD_NUM" BUILD_DIR="$BUILD_DIR" ./build.sh

APP="$BUILD_DIR/AILock.app"
STAGE="$BUILD_DIR/dmg"
DMG="$BUILD_DIR/AILock-$VERSION-local.dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/AILock.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "AI Lock" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo "Created local DMG: $(pwd)/$DMG"
echo "This development package is not notarized. Use '$0 --release' for external distribution."
