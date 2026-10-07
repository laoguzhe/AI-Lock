#!/bin/bash
# 编译 AI Lock 并打包成 .app（辅助功能权限只能授给 .app，不能授给裸二进制）
#
#   ./build.sh              开发构建：临时签名，编完即用
#   ./build.sh --release    分发构建：Developer ID 签名 + Hardened Runtime + 安全时间戳
#                           （这三项缺一样，公证都会直接被拒）
set -euo pipefail

cd "$(dirname "$0")"
APP="build/AILock.app"

RELEASE=0
[[ "${1:-}" == "--release" ]] && RELEASE=1

# 版本号走环境变量，发版时 VERSION=1.1 BUILD_NUM=3 ./release.sh 即可，不用改脚本
VERSION="${VERSION:-1.0}"
BUILD_NUM="${BUILD_NUM:-1}"
SIGN_ID="${SIGN_ID:-Developer ID Application: gu lao (TQ74Z4L53F)}"

rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/AILock" AppDelegate.swift ClipboardHistory.swift DashboardWindow.swift DockController.swift HardwareInfo.swift LogStore.swift NetworkInspector.swift ProcessMonitor.swift QuickSearch.swift ResourceAlerts.swift SecurityExtensionStatus.swift SystemMonitor.swift

# 图标：1024 原图现画，再由 sips 派生各尺寸交给 iconutil 打包
swiftc -swift-version 5 -o build/makeicon makeicon.swift
build/makeicon build/icon.png >/dev/null
ICONSET=build/AILock.iconset
mkdir -p "$ICONSET"
for sz in 16 32 128 256 512; do
	sips -z $sz $sz build/icon.png --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
	sips -z $((sz*2)) $((sz*2)) build/icon.png --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>AI Lock</string>
	<key>CFBundleDisplayName</key><string>AI Lock</string>
	<key>CFBundleIdentifier</key><string>com.laogu.ailock</string>
	<key>CFBundleExecutable</key><string>AILock</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$BUILD_NUM</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
	<key>NSHumanReadableCopyright</key><string>Copyright © 2026 gu lao. All rights reserved.</string>
	<key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

if [[ $RELEASE == 1 ]]; then
	# --options runtime  开 Hardened Runtime，公证的硬性前提
	# --timestamp        向 Apple 时间戳服务器取安全时间戳；证书过期后已签的包仍然有效
	# 本 App 不需要任何 entitlement：辅助功能是 TCC 运行时授权，不走 entitlement。
	codesign --force --options runtime --timestamp \
		--sign "$SIGN_ID" "$APP"
	codesign --verify --strict --verbose=2 "$APP"
	echo "✅ 已生成并正式签名 $(pwd)/$APP  (v$VERSION build $BUILD_NUM)"
else
	# 临时签名：让系统能稳定认出"还是同一个 App"，否则每次重编都要重新授权
	codesign --force --sign - --timestamp=none "$APP"
	echo "✅ 已生成 $(pwd)/$APP（开发版·临时签名）"
fi
