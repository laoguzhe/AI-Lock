#!/bin/bash
# Build and notarize a macOS DMG, commit and push release changes, then publish
# the Apple Silicon DMG, checksum, and public update manifest as GitHub Release assets.
set -euo pipefail

cd "$(dirname "$0")"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
run_step() {
	local step_label started elapsed result
	step_label="${1:?run_step requires a description}"
	shift
	log "▶ ${step_label}"
	started=$SECONDS
	if "$@"; then
		elapsed=$((SECONDS - started))
		log "✓ ${step_label}（${elapsed} 秒）"
	else
		result=$?
		log "✗ ${step_label} 失败（退出码 ${result}）"
		return "${result}"
	fi
}
trap 'result=$?; log "✗ 发布流程在第 ${LINENO} 行中断（退出码 ${result}）：${BASH_COMMAND}"; exit "$result"' ERR

export AILOCK_ARCHS=arm64

[[ $# -eq 0 ]] || { echo "Usage: ./fabu.sh" >&2; exit 2; }

CURRENT_VERSION="$(cat VERSION)"
[[ "$CURRENT_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo "Invalid VERSION: $CURRENT_VERSION" >&2; exit 2; }
VERSION="$(python3 - "$CURRENT_VERSION" <<'PY'
import sys
parts = sys.argv[1].split(".")
parts[-1] = str(int(parts[-1]) + 1)
print(".".join(parts))
PY
)"
BUILD_NUM="$(( $(cat BUILD_NUM) + 1 ))"

run_step "检查 GitHub CLI 版本" gh --version
run_step "检查 Apple Xcode 命令行工具" xcrun --version
[[ "$(uname -s)" == "Darwin" ]] || { echo "DMG publishing must run on macOS." >&2; exit 1; }
log "✓ 当前系统为 macOS"
run_step "检查 GitHub 登录状态" gh auth status --hostname github.com

BRANCH="$(git branch --show-current)"
[[ -n "$BRANCH" ]] || { echo "Run this script from a named branch." >&2; exit 1; }
log "✓ 当前 Git 分支：$BRANCH"
log "▶ 检查 GitHub 仓库发布条件"
REMOTE_INFO="$(gh repo view --json isPrivate,defaultBranchRef,nameWithOwner --jq '[.isPrivate, .defaultBranchRef.name, .nameWithOwner] | @tsv')"
IFS=$'\t' read -r IS_PRIVATE DEFAULT_BRANCH REPOSITORY <<<"$REMOTE_INFO"
[[ "$IS_PRIVATE" == "false" ]] || { echo "Refusing to publish updates: $REPOSITORY must be Public so installed apps can download releases." >&2; exit 1; }
[[ "$BRANCH" == "$DEFAULT_BRANCH" ]] || {
	echo "Current branch '$BRANCH' is not GitHub's default branch '$DEFAULT_BRANCH'." >&2
	exit 1
}
log "✓ 仓库 $REPOSITORY 为公开仓库，当前分支是默认分支 $DEFAULT_BRANCH"

TAG="v$VERSION"
log "▶ 检查版本标签 $TAG 是否已发布"
if gh release view "$TAG" >/dev/null 2>&1; then
	echo "GitHub Release $TAG already exists; refusing to replace it." >&2
	exit 1
fi
log "✓ 版本标签 $TAG 尚不存在，可以继续发布"

BUILD_DIR="build/publish-$VERSION"
UPLOAD_DIR="$BUILD_DIR/upload"
DMG="$BUILD_DIR/AILock-$VERSION.dmg"
UPLOAD_DMG="$UPLOAD_DIR/AILock.dmg"
CHECKSUM="$UPLOAD_DIR/AILock.dmg.sha256"
MANIFEST="$UPLOAD_DIR/AILock-update.json"

log "▶ 开始构建和公证 ${TAG}（build ${BUILD_NUM}）"
run_step "构建、签名、公证并验收 DMG" env VERSION="$VERSION" BUILD_NUM="$BUILD_NUM" BUILD_DIR="$BUILD_DIR" ./release.sh
run_step "创建 GitHub 上传目录" mkdir -p "$UPLOAD_DIR"
run_step "复制发布 DMG 到上传目录" cp "$DMG" "$UPLOAD_DMG"
log "▶ 计算 DMG SHA-256 校验和"
(cd "$UPLOAD_DIR" && shasum -a 256 AILock.dmg > AILock.dmg.sha256)
log "✓ 校验和已写入 $CHECKSUM"
run_step "生成公开自动更新清单" python3 - "$VERSION" "$BUILD_NUM" "$REPOSITORY" "$CHECKSUM" "$MANIFEST" <<'PY'
import json
import pathlib
import sys

version, build, repository, checksum_path, manifest_path = sys.argv[1:]
sha256 = pathlib.Path(checksum_path).read_text().split()[0]
manifest = {
    "version": version,
    "build": build,
    "downloadURL": f"https://github.com/{repository}/releases/latest/download/AILock.dmg",
    "sha256": sha256,
}
pathlib.Path(manifest_path).write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
PY

log "▶ 更新版本号文件"
printf '%s\n' "$VERSION" > VERSION
printf '%s\n' "$BUILD_NUM" > BUILD_NUM
log "✓ VERSION=${VERSION}，BUILD_NUM=${BUILD_NUM}"

# Build outputs are ignored; source, cleanup, release scripts and version files are committed together.
run_step "暂存发布所需源码、文档和版本文件" git add -A -- .
if ! git diff --cached --quiet; then
	run_step "创建发布提交" git commit -m "Release $TAG"
	log "✓ 发布提交已创建"
else
	log "ℹ 没有需要提交的版本变更"
fi
run_step "推送 $BRANCH 到 origin" git push origin "$BRANCH"

run_step "创建 GitHub Release 并上传 DMG、校验和与更新清单" gh release create "$TAG" "$UPLOAD_DMG" "$CHECKSUM" "$MANIFEST" \
	--title "AI Lock $VERSION · Apple Silicon" --generate-notes

log "✅ 公开 GitHub Release 已发布：$TAG"
log "发布文件：${UPLOAD_DMG}、${CHECKSUM} 和 ${MANIFEST}"
