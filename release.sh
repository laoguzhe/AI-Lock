#!/bin/bash
# 出一个可以直接放网站/GitHub 让人下载的 AI Lock DMG：
#   Developer ID 签名 → Apple 公证 → 装订(staple) → 打成 DMG → 再公证再装订
#
#   首次使用先存一次公证凭据（只需一次，存进钥匙串）：
#     xcrun notarytool store-credentials docklock-notary \
#       --apple-id <你的AppleID> --team-id TQ74Z4L53F --password <App专用密码>
#   App 专用密码在 https://appleid.apple.com → 登录与安全 → App 专用密码 生成。
#
#   发版：VERSION=1.2 BUILD_NUM=3 ./release.sh
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

VERSION="${VERSION:-$(cat VERSION)}"
BUILD_NUM="${BUILD_NUM:-$(cat BUILD_NUM)}"
SIGN_ID="${SIGN_ID:-Developer ID Application: gu lao (TQ74Z4L53F)}"
PROFILE="${NOTARY_PROFILE:-docklock-notary}"
BUILD_DIR="${BUILD_DIR:-build}"
export AILOCK_ARCHS=arm64

APP="$BUILD_DIR/AILock.app"
DMG="$BUILD_DIR/AILock-$VERSION.dmg"

# 早失败：凭据没存就别白编译一遍
log "▶ 检查 Apple 公证凭据（钥匙串配置：${PROFILE}）"
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
	cat >&2 <<EOF
❌ 找不到公证凭据 "$PROFILE"。先跑一次（只需一次）：

  xcrun notarytool store-credentials $PROFILE \\
    --apple-id <你的AppleID邮箱> --team-id TQ74Z4L53F --password <App专用密码>

App 专用密码：https://appleid.apple.com → 登录与安全 → App 专用密码
EOF
	exit 1
fi
log "✓ Apple 公证凭据可用"

run_step "编译并正式签名应用" env VERSION="$VERSION" BUILD_NUM="$BUILD_NUM" SIGN_ID="$SIGN_ID" BUILD_DIR="$BUILD_DIR" ./build.sh --release

# ---- 第一轮：公证 .app 本体 ----
# notarytool 不吃 .app 目录，必须先压成 zip；用 ditto -c -k --keepParent 才能保住签名结构
run_step "压缩 .app 并保留签名目录结构" ditto -c -k --keepParent "$APP" "$BUILD_DIR/AILock.zip"
run_step "提交 .app 给 Apple 公证并等待结果" xcrun notarytool submit "$BUILD_DIR/AILock.zip" --keychain-profile "$PROFILE" --wait

# 把公证票据写进 .app 自身。少了这步，用户从 DMG 拖出来的 App 在离线时首次启动会被拦。
run_step "将公证票据装订到 .app" xcrun stapler staple "$APP"

# ---- 打 DMG ----
log "▶ 准备 DMG 内容目录"
STAGE="$(mktemp -d "$BUILD_DIR/dmg-stage.XXXXXX")"
TEMP_DMG_BASE="$(mktemp "$BUILD_DIR/.AILock-$VERSION.XXXXXX")"
TEMP_DMG="${TEMP_DMG_BASE}.dmg"
mv "$TEMP_DMG_BASE" "$TEMP_DMG"
cleanup_release_artifacts() {
	[[ -z "${STAGE:-}" || ! -d "$STAGE" ]] || rm -rf "$STAGE"
	[[ -z "${TEMP_DMG:-}" || ! -f "$TEMP_DMG" ]] || rm -f "$TEMP_DMG"
    rm -f "$BUILD_DIR/AILock.zip" "$BUILD_DIR/makeicon" "$BUILD_DIR/icon.png"
    rm -rf "$BUILD_DIR/AILock.iconset"
}
trap cleanup_release_artifacts EXIT
run_step "复制已公证的应用到 DMG 暂存目录" cp -R "$APP" "$STAGE/"
run_step "添加拖拽安装用的 Applications 快捷方式" ln -s /Applications "$STAGE/Applications"

if hdiutil info | grep -Fq "$DMG"; then
	log "✗ 目标 DMG 当前已挂载或正被系统占用：$DMG"
	exit 1
fi
run_step "创建压缩 DMG（显示 hdiutil 详细日志）" hdiutil create -verbose -volname "AI Lock" -srcfolder "$STAGE" -ov -format UDZO "$TEMP_DMG"

# ---- 第二轮：签名并公证 DMG 本身 ----
run_step "正式签名 DMG" codesign --force --timestamp --sign "$SIGN_ID" "$TEMP_DMG"
run_step "提交 DMG 给 Apple 公证并等待结果" xcrun notarytool submit "$TEMP_DMG" --keychain-profile "$PROFILE" --wait
run_step "将公证票据装订到 DMG" xcrun stapler staple "$TEMP_DMG"

# ---- 验收：这两条是用户机器上 Gatekeeper 实际会跑的检查 ----
run_step "验证 DMG 公证票据" xcrun stapler validate "$TEMP_DMG"
run_step "使用 Gatekeeper 验证 DMG 安装包" spctl -a -vvv -t install "$TEMP_DMG"
run_step "使用 Gatekeeper 验证应用本体" spctl -a -vvv -t exec "$APP"
run_step "发布已验收的 DMG 到正式文件名" mv -f "$TEMP_DMG" "$DMG"
TEMP_DMG=""

echo
log "✅ 完成：$(pwd)/$DMG"
log "这个文件已完成签名、公证和 Gatekeeper 验收，可发布给用户。"
