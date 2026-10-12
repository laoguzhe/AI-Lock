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

# 版本号走环境变量，发版时 VERSION=1.2 BUILD_NUM=3 ./release.sh 即可，不用改脚本
VERSION="${VERSION:-1.2}"
BUILD_NUM="${BUILD_NUM:-3}"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ && "$BUILD_NUM" =~ ^[0-9]+$ ]] || { echo "Invalid VERSION or BUILD_NUM" >&2; exit 1; }
SIGN_ID="${SIGN_ID:-Developer ID Application: gu lao (TQ74Z4L53F)}"

# Preserve a user-supplied icon before recreating the build directory.
CUSTOM_ICON=""
if [[ -f icon.png ]]; then
	CUSTOM_ICON="$(mktemp /tmp/ailock-icon.XXXXXX)"
	cp icon.png "$CUSTOM_ICON"
elif [[ -f build/icon.png ]]; then
	CUSTOM_ICON="$(mktemp /tmp/ailock-icon.XXXXXX)"
	cp build/icon.png "$CUSTOM_ICON"
fi

rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

SOURCES=(NetworkDiagnosticService.swift NetworkDiagnosticsView.swift MenuBarOrganizer.swift Localization.swift AppDelegate.swift AgentHooks.swift AppSupport.swift AppSettings.swift MonitoringService.swift CacheCleaner.swift ClipboardHistory.swift ClipboardRepository.swift ClipboardTagView.swift ModuleViewController.swift ClipboardModuleController.swift FilesModuleController.swift ProcessesModuleController.swift NetworkModuleController.swift DashboardWindow.swift AIUsageTracker.swift MediaAccessMonitor.swift ScreenRecorder.swift DisplayBrightness.swift DockController.swift HardwareInfo.swift LogStore.swift MaintenanceTools.swift FileModels.swift FileScanService.swift DirectoryIndex.swift FileActivityService.swift DirectoryActivityMonitor.swift FileOperationPlan.swift ApplicationCatalog.swift NetworkHistory.swift NetworkInspector.swift NetworkObservationService.swift Notifications.swift ProcessMonitor.swift ProcessNetworkMonitor.swift QuickSearch.swift ResourceAlerts.swift SecurityExtensionStatus.swift SystemExtensionController.swift AuditExtensionClient.swift extensions/AuditIPC.swift ExtensionSettingsView.swift ContentFilterConfiguration.swift FilterHealthMonitor.swift NetworkFilterPolicy.swift SignedApplicationResolver.swift extensions/FilterHealthIPC.swift FilterConfigurationTransaction.swift SystemMonitor.swift)
# Compile a fixed source snapshot when other development tasks edit the workspace.
SOURCE_SNAPSHOT="$(mktemp -d /tmp/ailock-build-sources.XXXXXX)"
trap 'rm -rf "$SOURCE_SNAPSHOT"' EXIT
SNAPSHOT_SOURCES=()
for source in "${SOURCES[@]}"; do
    mkdir -p "$SOURCE_SNAPSHOT/$(dirname "$source")"
    cp "$source" "$SOURCE_SNAPSHOT/$source"
    SNAPSHOT_SOURCES+=("$SOURCE_SNAPSHOT/$source")
done
# Release artifacts contain both supported architectures; local builds use the host architecture.
if [[ $RELEASE == 1 ]]; then
    ARCHS="${AILOCK_ARCHS:-arm64 x86_64}"
else
    ARCHS="${AILOCK_ARCHS:-$(uname -m)}"
fi
BINARIES=()
for arch in $ARCHS; do
    [[ "$arch" == "arm64" || "$arch" == "x86_64" ]] || { echo "Unsupported architecture: $arch" >&2; exit 1; }
    binary="build/AILock-$arch"
    swiftc -O -swift-version 5 -target "$arch-apple-macos14.0" -o "$binary" "${SNAPSHOT_SOURCES[@]}"
    BINARIES+=("$binary")
done
if [[ ${#BINARIES[@]} -gt 1 ]]; then
    lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/AILock"
else
    cp "${BINARIES[0]}" "$APP/Contents/MacOS/AILock"
fi

cp -R Resources/NetworkDiagnostics "$APP/Contents/Resources/NetworkDiagnostics"

# Use the supplied PNG if present; otherwise generate the default app icon.
if [[ -n "$CUSTOM_ICON" ]]; then
	cp "$CUSTOM_ICON" build/icon.png
	rm -f "$CUSTOM_ICON"
else
	swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.0" -o build/makeicon makeicon.swift
	build/makeicon build/icon.png >/dev/null
fi
ICONSET=build/AILock.iconset
mkdir -p "$ICONSET"
for sz in 16 32 128 256 512; do
	sips -z $sz $sz build/icon.png --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
	sips -z $((sz*2)) $((sz*2)) build/icon.png --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp build/icon.png "$APP/Contents/Resources/StatusIcon.png"

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
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
	<key>NSHumanReadableCopyright</key><string>Copyright © 2026 gu lao. All rights reserved.</string>
	<key>NSSystemExtensionUsageDescription</key><string>AI Lock 在您启用后提供所选目录的文件操作审计和连接过滤。</string>
	<key>NSAppleEventsUsageDescription</key><string>AI Lock 在启动项删除遇到系统权限限制时，请求 Finder 将您确认的启动项移入废纸篓。</string>
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
	# 使用稳定的 Apple Developer 签名，避免 TCC 每次重建后丢失辅助功能授权。
	# Prefer an available stable development identity. Other contributors can build ad-hoc.
    DEFAULT_DEV_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/{print $2; exit}')"
    DEV_SIGN_ID="${DEV_SIGN_ID:-${DEFAULT_DEV_ID:--}}"
	codesign --force --sign "$DEV_SIGN_ID" --timestamp=none "$APP"
	codesign --verify --strict --verbose=2 "$APP"
	echo "✅ 已生成并签名 $(pwd)/${APP}（开发版；签名身份：${DEV_SIGN_ID}）"
fi
