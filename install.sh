#!/bin/bash
# 安装到 ~/Applications 并注册开机自启
set -euo pipefail

cd "$(dirname "$0")"
./build.sh

DEST="$HOME/Applications/AILock.app"
PLIST="$HOME/Library/LaunchAgents/com.laogu.ailock.plist"

# 先停掉旧实例，否则覆盖时会残留一个跑着老代码的进程
launchctl bootout "gui/$(id -u)/com.laogu.ailock" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.laogu.docklock" 2>/dev/null || true
pkill -x AILock 2>/dev/null || true
pkill -x DockLock 2>/dev/null || true

mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R build/AILock.app "$DEST"

# Migrate the legacy LaunchAgent to the same SMAppService used by the UI.
# Do not reset TCC: a stable development signature should retain the user's permission.
rm -f "$PLIST" "$HOME/Library/LaunchAgents/com.laogu.docklock.plist"
"$DEST/Contents/MacOS/AILock" --register-login-item
open "$DEST"

echo "✅ 已安装到 $DEST，登录项由应用设置统一管理"
echo "   若系统要求批准，请到系统设置 › 通用 › 登录项中允许 AI Lock。"
