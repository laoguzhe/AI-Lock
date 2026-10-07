#!/bin/bash
# 出一个可以直接放网站/GitHub 让人下载的 AI Lock DMG：
#   Developer ID 签名 → Apple 公证 → 装订(staple) → 打成 DMG → 再公证再装订
#
#   首次使用先存一次公证凭据（只需一次，存进钥匙串）：
#     xcrun notarytool store-credentials docklock-notary \
#       --apple-id <你的AppleID> --team-id TQ74Z4L53F --password <App专用密码>
#   App 专用密码在 https://appleid.apple.com → 登录与安全 → App 专用密码 生成。
#
#   发版：VERSION=1.1 BUILD_NUM=2 ./release.sh
set -euo pipefail

cd "$(dirname "$0")"

VERSION="${VERSION:-1.0}"
BUILD_NUM="${BUILD_NUM:-1}"
SIGN_ID="${SIGN_ID:-Developer ID Application: gu lao (TQ74Z4L53F)}"
PROFILE="${NOTARY_PROFILE:-docklock-notary}"

APP="build/AILock.app"
DMG="build/AILock-$VERSION.dmg"

# 早失败：凭据没存就别白编译一遍
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
	cat >&2 <<EOF
❌ 找不到公证凭据 "$PROFILE"。先跑一次（只需一次）：

  xcrun notarytool store-credentials $PROFILE \\
    --apple-id <你的AppleID邮箱> --team-id TQ74Z4L53F --password <App专用密码>

App 专用密码：https://appleid.apple.com → 登录与安全 → App 专用密码
EOF
	exit 1
fi

VERSION="$VERSION" BUILD_NUM="$BUILD_NUM" SIGN_ID="$SIGN_ID" ./build.sh --release

# ---- 第一轮：公证 .app 本体 ----
# notarytool 不吃 .app 目录，必须先压成 zip；用 ditto -c -k --keepParent 才能保住签名结构
echo "📦 打包 .app 送公证…"
ditto -c -k --keepParent "$APP" build/AILock.zip
xcrun notarytool submit build/AILock.zip --keychain-profile "$PROFILE" --wait

# 把公证票据写进 .app 自身。少了这步，用户从 DMG 拖出来的 App 在离线时首次启动会被拦。
xcrun stapler staple "$APP"

# ---- 打 DMG ----
echo "💿 生成 DMG…"
STAGE=build/dmg
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"     # 拖拽安装的那个快捷方式
rm -f "$DMG"
hdiutil create -volname "AI Lock" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

# ---- 第二轮：签名并公证 DMG 本身 ----
codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
echo "📦 送 DMG 公证…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

# ---- 验收：这两条是用户机器上 Gatekeeper 实际会跑的检查 ----
echo "🔍 验收…"
xcrun stapler validate "$DMG"
spctl -a -vvv -t install "$DMG"
spctl -a -vvv -t exec "$APP"

echo
echo "✅ 完成：$(pwd)/$DMG"
echo "   这个文件可以直接发布，用户下载双击拖进「应用程序」即可，无任何安全警告。"
