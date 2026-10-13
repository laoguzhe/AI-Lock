#!/bin/bash
# Build and notarize a macOS DMG, commit and push release changes, then publish
# the DMG and checksum as a GitHub Release asset. Repository visibility is not changed.
set -euo pipefail

cd "$(dirname "$0")"

usage() {
	cat <<'EOF'
Usage: ./publish-release.sh VERSION [BUILD_NUM] [NOTES_FILE]

Examples:
  ./publish-release.sh 1.3
  ./publish-release.sh 1.3 4 build/RELEASE_NOTES-1.3.md

If BUILD_NUM is omitted, it is incremented from BUILD_NUM in the repository.
If NOTES_FILE is omitted, GitHub generates release notes from commits.
EOF
}

[[ $# -ge 1 && $# -le 3 ]] || { usage >&2; exit 2; }

VERSION="$1"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo "Invalid VERSION: $VERSION" >&2; exit 2; }

CURRENT_BUILD_NUM="$(cat BUILD_NUM)"
if [[ $# -ge 2 ]]; then
	BUILD_NUM="$2"
else
	BUILD_NUM="$((CURRENT_BUILD_NUM + 1))"
fi
[[ "$BUILD_NUM" =~ ^[0-9]+$ ]] || { echo "Invalid BUILD_NUM: $BUILD_NUM" >&2; exit 2; }

NOTES_FILE="${3:-}"
if [[ -n "$NOTES_FILE" && ! -f "$NOTES_FILE" ]]; then
	echo "Release notes file not found: $NOTES_FILE" >&2
	exit 2
fi

command -v gh >/dev/null || { echo "GitHub CLI (gh) is required." >&2; exit 1; }
command -v xcrun >/dev/null || { echo "Xcode Command Line Tools are required." >&2; exit 1; }
[[ "$(uname -s)" == "Darwin" ]] || { echo "DMG publishing must run on macOS." >&2; exit 1; }
gh auth status --hostname github.com >/dev/null

BRANCH="$(git branch --show-current)"
[[ -n "$BRANCH" ]] || { echo "Run this script from a named branch." >&2; exit 1; }
REMOTE_INFO="$(gh repo view --json isPrivate,defaultBranchRef,nameWithOwner --jq '[.isPrivate, .defaultBranchRef.name, .nameWithOwner] | @tsv')"
IFS=$'\t' read -r IS_PRIVATE DEFAULT_BRANCH REPOSITORY <<<"$REMOTE_INFO"
[[ "$IS_PRIVATE" == "true" ]] || { echo "Refusing to publish: $REPOSITORY is not Private." >&2; exit 1; }
[[ "$BRANCH" == "$DEFAULT_BRANCH" ]] || {
	echo "Current branch '$BRANCH' is not GitHub's default branch '$DEFAULT_BRANCH'." >&2
	exit 1
}

TAG="v$VERSION"
if gh release view "$TAG" >/dev/null 2>&1; then
	echo "GitHub Release $TAG already exists; refusing to replace it." >&2
	exit 1
fi

BUILD_DIR="build/publish-$VERSION"
UPLOAD_DIR="$BUILD_DIR/upload"
DMG="$BUILD_DIR/AILock-$VERSION.dmg"
UPLOAD_DMG="$UPLOAD_DIR/AILock.dmg"
CHECKSUM="$UPLOAD_DIR/AILock.dmg.sha256"

echo "Building and notarizing $TAG (build $BUILD_NUM)…"
VERSION="$VERSION" BUILD_NUM="$BUILD_NUM" BUILD_DIR="$BUILD_DIR" ./release.sh
mkdir -p "$UPLOAD_DIR"
cp "$DMG" "$UPLOAD_DMG"
(cd "$UPLOAD_DIR" && shasum -a 256 AILock.dmg > AILock.dmg.sha256)

# Keep the release asset name stable so README's latest-download URL keeps working.
python3 - <<'PY'
from pathlib import Path

readme = Path("README.md")
text = readme.read_text()
text = text.replace(
    "https://github.com/laoguzhe/AI-Lock/releases/latest/download/AILock-1.2.dmg",
    "https://github.com/laoguzhe/AI-Lock/releases/latest/download/AILock.dmg",
)
readme.write_text(text)
PY
printf '%s\n' "$VERSION" > VERSION
printf '%s\n' "$BUILD_NUM" > BUILD_NUM

# Build outputs are ignored by Git. Stage current source/docs/version changes for
# the release commit, then push the default branch before creating the Release.
git add -A
if ! git diff --cached --quiet; then
	git commit -m "Release $TAG"
fi
git push origin "$BRANCH"

if [[ -n "$NOTES_FILE" ]]; then
	gh release create "$TAG" "$UPLOAD_DMG" "$CHECKSUM" \
		--title "AI Lock $VERSION" --notes-file "$NOTES_FILE"
else
	gh release create "$TAG" "$UPLOAD_DMG" "$CHECKSUM" \
		--title "AI Lock $VERSION" --generate-notes
fi

echo "Published private GitHub Release: $TAG"
echo "Assets: $UPLOAD_DMG and $CHECKSUM"
