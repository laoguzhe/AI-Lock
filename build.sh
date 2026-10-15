#!/bin/bash
# 编译 AI Lock 并打包成 .app（辅助功能权限只能授给 .app，不能授给裸二进制）
#
#   ./build.sh              开发构建：稳定开发者签名，编完即用
#   ./build.sh --release    分发构建：Developer ID 签名 + Hardened Runtime + 安全时间戳
#                           （这三项缺一样，公证都会直接被拒）
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

BUILD_DIR="${BUILD_DIR:-build}"
APP="$BUILD_DIR/AILock.app"
[[ "${AILOCK_ARCHS:-arm64}" == "arm64" ]] || { echo "AI Lock supports Apple Silicon (arm64) only." >&2; exit 2; }

RELEASE=0
[[ "${1:-}" == "--release" ]] && RELEASE=1

# 版本号走环境变量，发版时 VERSION=1.2 BUILD_NUM=3 ./release.sh 即可，不用改脚本
VERSION="${VERSION:-$(cat VERSION)}"
BUILD_NUM="${BUILD_NUM:-$(cat BUILD_NUM)}"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ && "$BUILD_NUM" =~ ^[0-9]+$ ]] || { echo "Invalid VERSION or BUILD_NUM" >&2; exit 1; }
SIGN_ID="${SIGN_ID:-Developer ID Application: gu lao (TQ74Z4L53F)}"

# Preserve a user-supplied icon before recreating the build directory.
CUSTOM_ICON=""
if [[ -f icon.png ]]; then
	CUSTOM_ICON="$(mktemp /tmp/ailock-icon.XXXXXX)"
	run_step "暂存自定义图标" cp icon.png "$CUSTOM_ICON"
elif [[ -f "$BUILD_DIR/icon.png" ]]; then
	CUSTOM_ICON="$(mktemp /tmp/ailock-icon.XXXXXX)"
	run_step "暂存现有应用图标" cp "$BUILD_DIR/icon.png" "$CUSTOM_ICON"
fi

run_step "清理旧应用目录" rm -rf "$APP"
run_step "创建应用目录结构" mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

SOURCES=(LumenDesignSystem.swift LumenShell.swift LumenOverviewView.swift LumenProcessesView.swift LumenNetworkView.swift LumenFileActivityView.swift LumenClipboardView.swift LumenUninstallerView.swift LumenLogsView.swift LumenScreenViews.swift LumenPreferencesView.swift LumenModuleHost.swift NetworkDiagnosticService.swift NetworkDiagnosticsView.swift MenuBarOrganizer.swift Localization.swift AppDelegate.swift UpdateService.swift AgentHooks.swift AppSupport.swift AppSettings.swift MonitoringService.swift CacheCleaner.swift ClipboardHistory.swift ClipboardRepository.swift ClipboardTagView.swift ModuleViewController.swift ClipboardModuleController.swift FilesModuleController.swift ProcessesModuleController.swift NetworkModuleController.swift DashboardWindow.swift AIUsageTracker.swift MediaAccessMonitor.swift ScreenRecorder.swift DisplayBrightness.swift DockController.swift HardwareInfo.swift LogStore.swift MaintenanceTools.swift FileModels.swift FileScanService.swift DirectoryIndex.swift FileActivityService.swift DirectoryActivityMonitor.swift FileOperationPlan.swift ApplicationCatalog.swift NetworkHistory.swift NetworkInspector.swift NetworkObservationService.swift Notifications.swift ProcessMonitor.swift ProcessNetworkMonitor.swift QuickSearch.swift ResourceAlerts.swift SecurityExtensionStatus.swift SystemExtensionController.swift AuditExtensionClient.swift extensions/AuditIPC.swift ExtensionSettingsView.swift ContentFilterConfiguration.swift FilterHealthMonitor.swift NetworkFilterPolicy.swift SignedApplicationResolver.swift extensions/FilterHealthIPC.swift FilterConfigurationTransaction.swift SystemMonitor.swift)
# Compile a fixed source snapshot when other development tasks edit the workspace.
SOURCE_SNAPSHOT="$(mktemp -d /tmp/ailock-build-sources.XXXXXX)"
trap 'rm -rf "$SOURCE_SNAPSHOT"; [[ -z "$CUSTOM_ICON" ]] || rm -f "$CUSTOM_ICON"' EXIT
SNAPSHOT_SOURCES=()
for source in "${SOURCES[@]}"; do
    mkdir -p "$SOURCE_SNAPSHOT/$(dirname "$source")"
    cp "$source" "$SOURCE_SNAPSHOT/$source"
    SNAPSHOT_SOURCES+=("$SOURCE_SNAPSHOT/$source")
done
log "✓ 已固定本次构建的源码快照（${#SOURCES[@]} 个源文件）"
# All builds target Apple Silicon; Intel/universal artifacts are no longer produced.
run_step "编译 Apple Silicon（arm64）版本" swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -o "$APP/Contents/MacOS/AILock" "${SNAPSHOT_SOURCES[@]}"
[[ "$(lipo -archs "$APP/Contents/MacOS/AILock")" == "arm64" ]] || { echo "Unexpected application architecture" >&2; exit 1; }

run_step "复制网络诊断资源" cp -R Resources/NetworkDiagnostics "$APP/Contents/Resources/NetworkDiagnostics"
run_step "复制中英文权限说明" cp -R Resources/en.lproj Resources/zh-Hans.lproj "$APP/Contents/Resources/"
run_step "复制开源许可文件" cp LICENSE "$APP/Contents/Resources/LICENSE.txt"

# Use the supplied PNG if present; otherwise generate the default app icon.
if [[ -n "$CUSTOM_ICON" ]]; then
	cp "$CUSTOM_ICON" "$BUILD_DIR/icon.png"
	rm -f "$CUSTOM_ICON"
else
	log "▶ 编译默认应用图标"
	swiftc -swift-version 5 -target arm64-apple-macos14.0 -o "$BUILD_DIR/makeicon" makeicon.swift
	"$BUILD_DIR/makeicon" "$BUILD_DIR/icon.png" >/dev/null
fi
ICONSET="$BUILD_DIR/AILock.iconset"
run_step "创建图标集目录" mkdir -p "$ICONSET"
log "▶ 生成不同尺寸的应用图标"
for sz in 16 32 128 256 512; do
	sips -z $sz $sz "$BUILD_DIR/icon.png" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
	sips -z $((sz*2)) $((sz*2)) "$BUILD_DIR/icon.png" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done
log "✓ 已生成图标尺寸"
run_step "生成 macOS 图标文件" iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
run_step "复制菜单栏状态图标" cp "$BUILD_DIR/icon.png" "$APP/Contents/Resources/StatusIcon.png"

log "▶ 写入应用版本与系统权限说明"
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
	<key>CFBundleIconName</key><string>AppIcon</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$BUILD_NUM</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
	<key>NSHumanReadableCopyright</key><string>Copyright © 2026 gu lao. All rights reserved.</string>
	<key>NSSystemExtensionUsageDescription</key><string>When enabled, AI Lock audits file operations in selected directories and filters connections.</string>
	<key>NSAppleEventsUsageDescription</key><string>When a startup item cannot be removed due to system permissions, AI Lock asks Finder to move the startup item you confirmed to Trash.</string>
	<key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

if [[ $RELEASE == 1 ]]; then
	# --options runtime  开 Hardened Runtime，公证的硬性前提
	# --timestamp        向 Apple 时间戳服务器取安全时间戳；证书过期后已签的包仍然有效
	# 本 App 不需要任何 entitlement：辅助功能是 TCC 运行时授权，不走 entitlement。
	run_step "正式签名应用（Developer ID + Hardened Runtime）" codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
	run_step "校验应用签名" codesign --verify --strict --verbose=2 "$APP"
	echo "✅ 已生成并正式签名 $(pwd)/$APP  (v$VERSION build $BUILD_NUM)"
else
	# 使用稳定的 Apple Developer 签名，避免 TCC 每次重建后丢失辅助功能授权。
	# Prefer an available stable development identity. Other contributors can build ad-hoc.
    DEFAULT_DEV_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/{print $2; exit}')"
    DEV_SIGN_ID="${DEV_SIGN_ID:-${DEFAULT_DEV_ID:--}}"
	run_step "签名开发版应用" codesign --force --sign "$DEV_SIGN_ID" --timestamp=none "$APP"
	run_step "校验应用签名" codesign --verify --strict --verbose=2 "$APP"
	echo "✅ 已生成并签名 $(pwd)/${APP}（开发版；签名身份：${DEV_SIGN_ID}）"
fi
